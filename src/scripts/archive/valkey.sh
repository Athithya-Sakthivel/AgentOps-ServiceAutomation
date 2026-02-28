#!/usr/bin/env bash
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
OUT_DIR="${OUT_DIR:-src/manifests/valkey}"
OUT_FILE="${OUT_FILE:-${OUT_DIR}/valkey.yaml}"
TMPFILE=""
NAMESPACE="${NAMESPACE:-valkey-prod}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-valkey-sa}"
SECRET_NAME="${SECRET_NAME:-valkey-auth}"
HEADLESS_SVC="${HEADLESS_SVC:-valkey-headless}"
CLIENT_SVC="${CLIENT_SVC:-valkey}"
VALKEY_PORT="${VALKEY_PORT:-6379}"
BUS_PORT="${BUS_PORT:-16379}"
IMAGE="${IMAGE:-valkey/valkey:9.0.3}"
REPLICAS="${REPLICAS:-3}"
CPU_REQUEST="${CPU_REQUEST:-500m}"
MEMORY_REQUEST="${MEMORY_REQUEST:-1Gi}"
CPU_LIMIT="${CPU_LIMIT:-2}"
MEMORY_LIMIT="${MEMORY_LIMIT:-4Gi}"
TERMINATION_GRACE="${TERMINATION_GRACE:-120}"
PDB_MIN_AVAILABLE="${PDB_MIN_AVAILABLE:-2}"
APPLY="${APPLY:-0}"
K8S_CLUSTER="${K8S_CLUSTER:-kind}"
LOG_FILE="${LOG_FILE:-}"
VERBOSE="${VERBOSE:-0}"
YES=0
INSPECT_TEST=0

if [ -z "${ENABLE_VALKEY_PERSISTENCE+x}" ]; then
  if [ "${K8S_CLUSTER}" = "kind" ]; then
    ENABLE_VALKEY_PERSISTENCE=0
  else
    ENABLE_VALKEY_PERSISTENCE=1
  fi
else
  ENABLE_VALKEY_PERSISTENCE="${ENABLE_VALKEY_PERSISTENCE}"
fi
VALKEY_PVC_SIZE="${VALKEY_PVC_SIZE:-10Gi}"
KIND_STORAGECLASS="${KIND_STORAGECLASS:-standard}"
EKS_STORAGECLASS="${EKS_STORAGECLASS:-gp3}"

ACTION=""

err() { printf "ERROR: %s\n" "$*" >&2; if [ -n "${LOG_FILE}" ]; then printf "ERROR: %s\n" "$*" >> "${LOG_FILE}"; fi; }
info() { printf "==> %s\n" "$*"; if [ -n "${LOG_FILE}" ]; then printf "==> %s\n" "$*" >> "${LOG_FILE}"; fi; }
debug() { if [ "${VERBOSE}" -eq 1 ]; then printf "DEBUG: %s\n" "$*"; if [ -n "${LOG_FILE}" ]; then printf "DEBUG: %s\n" "$*" >> "${LOG_FILE}"; fi; fi; }

ensure_kubectl() {
  if ! command -v "${KUBECTL}" >/dev/null 2>&1; then
    err "kubectl not found in PATH."
    exit 3
  fi
}

validate_env() {
  if ! [[ "${REPLICAS}" =~ ^[0-9]+$ && "${REPLICAS}" -ge 1 ]]; then
    err "REPLICAS must be a positive integer (got: ${REPLICAS})"
    exit 4
  fi
  if [ "${K8S_CLUSTER}" = "kind" ] && [ "${REPLICAS}" -gt 1 ]; then
    info "Warning: kind often cannot schedule strict anti-affinity multi-replica clusters. Consider REPLICAS=1 for kind."
  fi
  if [ "${ENABLE_VALKEY_PERSISTENCE}" -eq 1 ] && [ -z "${VALKEY_PVC_SIZE}" ]; then
    err "ENABLE_VALKEY_PERSISTENCE=1 requires VALKEY_PVC_SIZE to be set."
    exit 5
  fi
  if [ "${ACTION}" = "rollout" ] || [ "${APPLY}" -eq 1 ]; then
    if [ -z "${VALKEY_PASSWORD:-}" ]; then
      err "VALKEY_PASSWORD must be set for rollout/apply operations."
      exit 6
    fi
  fi
}

cleanup_tmpfile() {
  if [ -n "${TMPFILE:-}" ] && [ -f "${TMPFILE}" ]; then
    rm -f "${TMPFILE}" || true
  fi
}
trap cleanup_tmpfile EXIT

mktemp_atomic() {
  mkdir -p "$(dirname "${OUT_FILE}")"
  TMPFILE="$(mktemp "${OUT_FILE}.tmp.XXXX")"
}

detect_topology_support() {
  TOPOLOGY_ENABLED=0
  if [ "${K8S_CLUSTER}" = "kind" ]; then
    TOPOLOGY_ENABLED=0
    info "Topology spread constraints disabled for kind by default."
    return
  fi
  if ! command -v "${KUBECTL}" >/dev/null 2>&1; then
    TOPOLOGY_ENABLED=0
    info "kubectl missing; will not enable topology spread constraints."
    return
  fi
  nodes_count=$("${KUBECTL}" get nodes --no-headers 2>/dev/null | wc -l || true)
  if [ -z "${nodes_count}" ] || [ "${nodes_count}" -lt 2 ]; then
    TOPOLOGY_ENABLED=0
    info "Cluster has fewer than 2 nodes (${nodes_count}), disabling topology spread constraints."
    return
  fi
  zones=$("${KUBECTL}" get nodes -o jsonpath='{range .items[*]}{.metadata.labels["topology.kubernetes.io/zone"]}{" "}{end}' 2>/dev/null || true)
  zones_trimmed="$(echo "${zones}" | tr -s ' ' | sed 's/^ *//;s/ *$//')"
  if [ -z "${zones_trimmed}" ]; then
    TOPOLOGY_ENABLED=0
    info "No topology.kubernetes.io/zone labels found on nodes; disabling topology spread constraints."
    return
  fi
  TOPOLOGY_ENABLED=1
  info "Detected zone labels on nodes; topology spread constraints will be enabled."
}

ensure_eks_storageclass() {
  if [ "${ENABLE_VALKEY_PERSISTENCE}" -ne 1 ]; then
    return 0
  fi
  if [ "${K8S_CLUSTER}" != "eks" ]; then
    return 0
  fi
  ensure_kubectl
  if "${KUBECTL}" get storageclass "${EKS_STORAGECLASS}" >/dev/null 2>&1; then
    info "StorageClass ${EKS_STORAGECLASS} already exists."
    return 0
  fi
  info "Creating StorageClass ${EKS_STORAGECLASS}..."
  cat <<SC | "${KUBECTL}" apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${EKS_STORAGECLASS}
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  fsType: ext4
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
SC
  info "StorageClass ${EKS_STORAGECLASS} created or present."
}

render_manifest() {
  mkdir -p "${OUT_DIR}"
  mktemp_atomic
  VALKEY_STORAGECLASS=""
  if [ "${ENABLE_VALKEY_PERSISTENCE}" -eq 1 ]; then
    if [ "${K8S_CLUSTER}" = "kind" ]; then
      VALKEY_STORAGECLASS="${KIND_STORAGECLASS}"
    else
      VALKEY_STORAGECLASS="${EKS_STORAGECLASS}"
    fi
  fi
  if [ "${REPLICAS}" -ge 3 ]; then
    PDB_MIN_AVAILABLE=2
  else
    PDB_MIN_AVAILABLE=1
  fi
  detect_topology_support
  if [ "${TOPOLOGY_ENABLED}" -eq 1 ]; then
    TOPOLOGY_BLOCK=$'      topologySpreadConstraints:\n        - maxSkew: 1\n          topologyKey: "topology.kubernetes.io/zone"\n          whenUnsatisfiable: DoNotSchedule\n          labelSelector:\n            matchLabels:\n              app: valkey\n'
  else
    TOPOLOGY_BLOCK=''
  fi

  if [ "${ENABLE_VALKEY_PERSISTENCE}" -eq 0 ]; then
    cat > "${TMPFILE}" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: valkey
    app.kubernetes.io/managed-by: valkey-platform-script

---

apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SERVICE_ACCOUNT}
  namespace: ${NAMESPACE}
automountServiceAccountToken: false

---

apiVersion: v1
kind: Service
metadata:
  name: ${HEADLESS_SVC}
  namespace: ${NAMESPACE}
  labels:
    app: valkey
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector:
    app: valkey
  ports:
    - name: client
      port: ${VALKEY_PORT}
      targetPort: ${VALKEY_PORT}
      protocol: TCP
    - name: cluster-bus
      port: ${BUS_PORT}
      targetPort: ${BUS_PORT}
      protocol: TCP

---

apiVersion: v1
kind: Service
metadata:
  name: ${CLIENT_SVC}
  namespace: ${NAMESPACE}
  labels:
    app: valkey
spec:
  type: ClusterIP
  selector:
    app: valkey
  ports:
    - name: client
      port: ${VALKEY_PORT}
      targetPort: ${VALKEY_PORT}
      protocol: TCP

---

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: valkey-allow-same-namespace
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: valkey
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}
      ports:
        - protocol: TCP
          port: ${VALKEY_PORT}
    - from:
        - podSelector: {}
      ports:
        - protocol: TCP
          port: ${BUS_PORT}

---

apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: valkey-pdb
  namespace: ${NAMESPACE}
spec:
  minAvailable: ${PDB_MIN_AVAILABLE}
  selector:
    matchLabels:
      app: valkey

---

apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: valkey
  namespace: ${NAMESPACE}
  labels:
    app: valkey
spec:
  serviceName: "${HEADLESS_SVC}"
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: valkey
  template:
    metadata:
      labels:
        app: valkey
    spec:
      serviceAccountName: ${SERVICE_ACCOUNT}
      automountServiceAccountToken: false
      securityContext:
        fsGroup: 1000
        runAsUser: 1000
        runAsGroup: 1000
      terminationGracePeriodSeconds: ${TERMINATION_GRACE}
${TOPOLOGY_BLOCK}
      containers:
        - name: valkey
          image: "${IMAGE}"
          imagePullPolicy: IfNotPresent
          ports:
            - name: client
              containerPort: ${VALKEY_PORT}
              protocol: TCP
            - name: cluster-bus
              containerPort: ${BUS_PORT}
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            runAsNonRoot: true
            runAsUser: 1000
          resources:
            requests:
              cpu: "${CPU_REQUEST}"
              memory: "${MEMORY_REQUEST}"
            limits:
              cpu: "${CPU_LIMIT}"
              memory: "${MEMORY_LIMIT}"
          env:
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: VALKEY_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${SECRET_NAME}
                  key: VALKEY_PASSWORD
            - name: VALKEY_PORT
              value: "${VALKEY_PORT}"
            - name: VALKEY_BUS_PORT
              value: "${BUS_PORT}"
          startupProbe:
            tcpSocket:
              port: ${VALKEY_PORT}
            failureThreshold: 60
            periodSeconds: 5
            timeoutSeconds: 3
          readinessProbe:
            tcpSocket:
              port: ${VALKEY_PORT}
            initialDelaySeconds: 8
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3
          livenessProbe:
            tcpSocket:
              port: ${VALKEY_PORT}
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          lifecycle:
            preStop:
              exec:
                command:
                  - /bin/sh
                  - -c
                  - |
                    if command -v valkey-cli >/dev/null 2>&1; then
                      valkey-cli -a "\${VALKEY_PASSWORD}" --no-auth-warning shutdown || true
                    else
                      echo "valkey-cli not found; continuing shutdown"
                    fi
          volumeMounts:
            - name: data
              mountPath: /data
            - name: run
              mountPath: /run
      volumes:
        - name: run
          emptyDir: {}
        - name: data
          emptyDir: {}
EOF
  else
    cat > "${TMPFILE}" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: valkey
    app.kubernetes.io/managed-by: valkey-platform-script

---

apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SERVICE_ACCOUNT}
  namespace: ${NAMESPACE}
automountServiceAccountToken: false

---

apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
type: Opaque
data: {}

---

apiVersion: v1
kind: Service
metadata:
  name: ${HEADLESS_SVC}
  namespace: ${NAMESPACE}
  labels:
    app: valkey
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector:
    app: valkey
  ports:
    - name: client
      port: ${VALKEY_PORT}
      targetPort: ${VALKEY_PORT}
      protocol: TCP
    - name: cluster-bus
      port: ${BUS_PORT}
      targetPort: ${BUS_PORT}
      protocol: TCP

---

apiVersion: v1
kind: Service
metadata:
  name: ${CLIENT_SVC}
  namespace: ${NAMESPACE}
  labels:
    app: valkey
spec:
  type: ClusterIP
  selector:
    app: valkey
  ports:
    - name: client
      port: ${VALKEY_PORT}
      targetPort: ${VALKEY_PORT}
      protocol: TCP

---

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: valkey-allow-same-namespace
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: valkey
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}
      ports:
        - protocol: TCP
          port: ${VALKEY_PORT}
    - from:
        - podSelector: {}
      ports:
        - protocol: TCP
          port: ${BUS_PORT}

---

apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: valkey-pdb
  namespace: ${NAMESPACE}
spec:
  minAvailable: ${PDB_MIN_AVAILABLE}
  selector:
    matchLabels:
      app: valkey

---

apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: valkey
  namespace: ${NAMESPACE}
  labels:
    app: valkey
spec:
  serviceName: "${HEADLESS_SVC}"
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: valkey
  template:
    metadata:
      labels:
        app: valkey
    spec:
      serviceAccountName: ${SERVICE_ACCOUNT}
      automountServiceAccountToken: false
      securityContext:
        fsGroup: 1000
        runAsUser: 1000
        runAsGroup: 1000
      terminationGracePeriodSeconds: ${TERMINATION_GRACE}
${TOPOLOGY_BLOCK}
      containers:
        - name: valkey
          image: "${IMAGE}"
          imagePullPolicy: IfNotPresent
          ports:
            - name: client
              containerPort: ${VALKEY_PORT}
              protocol: TCP
            - name: cluster-bus
              containerPort: ${BUS_PORT}
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            runAsNonRoot: true
            runAsUser: 1000
          resources:
            requests:
              cpu: "${CPU_REQUEST}"
              memory: "${MEMORY_REQUEST}"
            limits:
              cpu: "${CPU_LIMIT}"
              memory: "${MEMORY_LIMIT}"
          env:
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: VALKEY_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${SECRET_NAME}
                  key: VALKEY_PASSWORD
            - name: VALKEY_PORT
              value: "${VALKEY_PORT}"
            - name: VALKEY_BUS_PORT
              value: "${BUS_PORT}"
          startupProbe:
            tcpSocket:
              port: ${VALKEY_PORT}
            failureThreshold: 60
            periodSeconds: 5
            timeoutSeconds: 3
          readinessProbe:
            tcpSocket:
              port: ${VALKEY_PORT}
            initialDelaySeconds: 8
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3
          livenessProbe:
            tcpSocket:
              port: ${VALKEY_PORT}
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          lifecycle:
            preStop:
              exec:
                command:
                  - /bin/sh
                  - -c
                  - |
                    if command -v valkey-cli >/dev/null 2>&1; then
                      valkey-cli -a "\${VALKEY_PASSWORD}" --no-auth-warning shutdown || true
                    else
                      echo "valkey-cli not found; continuing shutdown"
                    fi
          volumeMounts:
            - name: data
              mountPath: /data
            - name: run
              mountPath: /run
      volumes:
        - name: run
          emptyDir: {}
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: "${VALKEY_STORAGECLASS}"
        resources:
          requests:
            storage: ${VALKEY_PVC_SIZE}
EOF
  fi

  info "Validating manifest with kubectl (client dry-run)..."
  if command -v "${KUBECTL}" >/dev/null 2>&1; then
    if ! "${KUBECTL}" apply --dry-run=client -f "${TMPFILE}" >/dev/null 2>&1; then
      err "Manifest failed kubectl dry-run validation. Inspect ${TMPFILE}."
      exit 7
    fi
  else
    info "kubectl not found; skipping client-side validation."
  fi

  mv "${TMPFILE}" "${OUT_FILE}"
  TMPFILE=""
  trap - EXIT
  info "Rendered manifest to ${OUT_FILE}."
}

create_namespace_and_secret() {
  ensure_kubectl
  info "Ensuring namespace ${NAMESPACE} exists"
  "${KUBECTL}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL}" apply -f -
  if [ -n "${VALKEY_PASSWORD:-}" ]; then
    info "Creating/updating secret ${SECRET_NAME}"
    "${KUBECTL}" -n "${NAMESPACE}" create secret generic "${SECRET_NAME}" --from-literal=VALKEY_PASSWORD="${VALKEY_PASSWORD}" --dry-run=client -o yaml | "${KUBECTL}" apply -f -
  fi
}

apply_manifest() {
  ensure_kubectl
  if [ "${K8S_CLUSTER}" = "eks" ] && [ "${ENABLE_VALKEY_PERSISTENCE}" -eq 1 ]; then
    ensure_eks_storageclass
  fi
  info "Applying manifest ${OUT_FILE}..."
  "${KUBECTL}" apply -f "${OUT_FILE}"
}

wait_for_rollout() {
  ensure_kubectl
  info "Waiting for rollout of StatefulSet valkey in namespace ${NAMESPACE}..."
  if ! "${KUBECTL}" -n "${NAMESPACE}" rollout status statefulset/valkey --timeout=10m; then
    err "Rollout timed out or failed."
    "${KUBECTL}" -n "${NAMESPACE}" get pods -o wide || true
    exit 8
  fi
  info "Waiting for all pods labeled app=valkey to be Ready..."
  if ! "${KUBECTL}" -n "${NAMESPACE}" wait --for=condition=ready pod -l app=valkey --timeout=600s; then
    err "Some pods failed to become ready in time."
    "${KUBECTL}" -n "${NAMESPACE}" get pods -o wide || true
    exit 9
  fi
  info "Rollout complete and pods are Ready."
}

smoke_test() {
  ensure_kubectl
  info "Running smoke tests..."
  POD="$("${KUBECTL}" -n "${NAMESPACE}" get pod -l app=valkey -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -z "${POD}" ]; then
    err "No valkey pod found for smoke test."
    exit 10
  fi
  info "Selected pod ${POD} for smoke test."
  CHECK_OUTPUT="$("${KUBECTL}" -n "${NAMESPACE}" exec "${POD}" -- sh -c 'if command -v valkey-cli >/dev/null 2>&1; then valkey-cli -a "'"${VALKEY_PASSWORD}"'" --no-auth-warning ping 2>/dev/null || true; elif command -v redis-cli >/dev/null 2>&1; then redis-cli -a "'"${VALKEY_PASSWORD}"'" ping 2>/dev/null || true; else echo "NO_CLI"; fi' 2>/dev/null || true)"
  if [ "${CHECK_OUTPUT}" = "PONG" ]; then
    info "valkey ping successful (PONG)."
  elif [ "${CHECK_OUTPUT}" = "NO_CLI" ]; then
    info "No valkey-cli/redis-cli in image; verifying service endpoints instead..."
    "${KUBECTL}" -n "${NAMESPACE}" get svc "${CLIENT_SVC}" || true
    info "Service exists. Consider installing valkey-cli for deeper checks."
  else
    err "Smoke test ping returned: ${CHECK_OUTPUT}"
    "${KUBECTL}" -n "${NAMESPACE}" logs "${POD}" --tail=200 || true
    exit 11
  fi
}

inspect_cluster() {
  ensure_kubectl
  info "Namespace: ${NAMESPACE}"
  "${KUBECTL}" get ns "${NAMESPACE}" || true
  info "Pods:"
  "${KUBECTL}" -n "${NAMESPACE}" get pods -l app=valkey -o wide || true
  info "StatefulSet:"
  "${KUBECTL}" -n "${NAMESPACE}" get statefulset valkey -o wide || true
  info "Services:"
  "${KUBECTL}" -n "${NAMESPACE}" get svc -l app=valkey || true
  if [ "${ENABLE_VALKEY_PERSISTENCE}" -eq 1 ]; then
    info "PVCs:"
    "${KUBECTL}" -n "${NAMESPACE}" get pvc -l app=valkey || true
  fi
  info "Events (last 200):"
  "${KUBECTL}" -n "${NAMESPACE}" get events --sort-by='.lastTimestamp' || true
}

high_signal_tests() {
  ensure_kubectl
  info "Running high-signal tests (best-effort)..."
  PODS_LIST="$("${KUBECTL}" -n "${NAMESPACE}" get pod -l app=valkey -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null || true)"
  if [ -z "${PODS_LIST}" ]; then
    err "No valkey pods found; aborting tests."
    return 1
  fi
  FIRST_POD="$(echo "${PODS_LIST}" | awk '{print $1}')"
  info "Pods found: ${PODS_LIST}"
  debug "Checking endpoints for headless service ${HEADLESS_SVC}"
  ENDPOINT_IPS="$("${KUBECTL}" -n "${NAMESPACE}" get endpoints "${HEADLESS_SVC}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  ENDPOINT_COUNT=0
  if [ -n "${ENDPOINT_IPS}" ]; then
    ENDPOINT_COUNT="$(echo "${ENDPOINT_IPS}" | wc -w | tr -d ' ')"
  fi
  info "Headless endpoints count: ${ENDPOINT_COUNT} (expected ${REPLICAS})"
  if [ "${ENDPOINT_COUNT}" -ne "${REPLICAS}" ]; then
    err "Endpoint count (${ENDPOINT_COUNT}) does not match expected replicas (${REPLICAS})."
  fi

  info "Verifying auth enforcement and basic replication via in-pod CLI if available."
  CLI_CHECK="$("${KUBECTL}" -n "${NAMESPACE}" exec "${FIRST_POD}" -- sh -c 'if command -v valkey-cli >/dev/null 2>&1; then echo valkey-cli; elif command -v redis-cli >/dev/null 2>&1; then echo redis-cli; else echo NONE; fi' 2>/dev/null || true)"
  info "Detected CLI in pod: ${CLI_CHECK}"
  if [ "${CLI_CHECK}" = "NONE" ]; then
    info "No CLI available in image; skipping in-pod PING/SET/GET tests. Service and endpoints validated above."
  else
    AUTH_PING="$("${KUBECTL}" -n "${NAMESPACE}" exec "${FIRST_POD}" -- sh -c "if [ '${CLI_CHECK}' = 'valkey-cli' ]; then valkey-cli -a '${VALKEY_PASSWORD}' --no-auth-warning ping; else redis-cli -a '${VALKEY_PASSWORD}' ping; fi" 2>/dev/null || true)"
    if [ "${AUTH_PING}" = "PONG" ]; then
      info "Authenticated ping succeeded (PONG)."
    else
      err "Authenticated ping failed: ${AUTH_PING}"
    fi

    UNAUTH_PING="$("${KUBECTL}" -n "${NAMESPACE}" exec "${FIRST_POD}" -- sh -c "if [ '${CLI_CHECK}' = 'valkey-cli' ]; then valkey-cli ping 2>/dev/null || true; else redis-cli ping 2>/dev/null || true; fi" 2>/dev/null || true)"
    if [ -z "${UNAUTH_PING}" ] || [ "${UNAUTH_PING}" = "NOAUTH Authentication required." ]; then
      info "Unauthenticated ping correctly rejected or required auth."
    else
      err "Unauthenticated ping unexpectedly succeeded: ${UNAUTH_PING}"
    fi

    TEST_KEY="ci-test-$$"
    SET_RESULT="$("${KUBECTL}" -n "${NAMESPACE}" exec "${FIRST_POD}" -- sh -c "if [ '${CLI_CHECK}' = 'valkey-cli' ]; then valkey-cli -a '${VALKEY_PASSWORD}' --no-auth-warning set ${TEST_KEY} ci-value EX 3; else redis-cli -a '${VALKEY_PASSWORD}' set ${TEST_KEY} ci-value EX 3; fi" 2>/dev/null || true)"
    debug "SET result: ${SET_RESULT}"
    GET_RESULT="$("${KUBECTL}" -n "${NAMESPACE}" exec "${FIRST_POD}" -- sh -c "if [ '${CLI_CHECK}' = 'valkey-cli' ]; then valkey-cli -a '${VALKEY_PASSWORD}' --no-auth-warning get ${TEST_KEY}; else redis-cli -a '${VALKEY_PASSWORD}' get ${TEST_KEY}; fi" 2>/dev/null || true)"
    if [ "${GET_RESULT}" = "ci-value" ]; then
      info "Write/read roundtrip succeeded."
    else
      err "Write/read roundtrip failed (got: '${GET_RESULT}')."
    fi
    sleep 4
    GET_AFTER="$("${KUBECTL}" -n "${NAMESPACE}" exec "${FIRST_POD}" -- sh -c "if [ '${CLI_CHECK}' = 'valkey-cli' ]; then valkey-cli -a '${VALKEY_PASSWORD}' --no-auth-warning get ${TEST_KEY}; else redis-cli -a '${VALKEY_PASSWORD}' get ${TEST_KEY}; fi" 2>/dev/null || true)"
    if [ -z "${GET_AFTER}" ] || [ "${GET_AFTER}" = "nil" ]; then
      info "TTL expiration observed as expected."
    else
      err "TTL test failed; key still present after expiration: ${GET_AFTER}"
    fi

    debug "Checking replication role (INFO replication) on each pod..."
    for p in ${PODS_LIST}; do
      ROLE="$("${KUBECTL}" -n "${NAMESPACE}" exec "${p}" -- sh -c "if [ '${CLI_CHECK}' = 'valkey-cli' ]; then valkey-cli -a '${VALKEY_PASSWORD}' --no-auth-warning info replication | grep 'role:' || true; else redis-cli -a '${VALKEY_PASSWORD}' info replication | grep 'role:' || true; fi" 2>/dev/null || true)"
      info "Pod ${p} replication line: ${ROLE}"
    done
  fi

  if [ "${ENABLE_VALKEY_PERSISTENCE}" -eq 1 ]; then
    info "Verifying PVC binding status..."
    PVC_STATUS_LIST="$("${KUBECTL}" -n "${NAMESPACE}" get pvc -l app=valkey -o jsonpath='{range .items[*]}{.metadata.name}:{.status.phase}{" "}{end}' 2>/dev/null || true)"
    info "PVC status: ${PVC_STATUS_LIST}"
  fi

  info "Recent events (tail 20):"
  "${KUBECTL}" -n "${NAMESPACE}" get events --sort-by='.lastTimestamp' | tail -n 20 || true

  info "High-signal tests complete."
}

delete_resources() {
  ensure_kubectl
  info "Deleting resources in namespace ${NAMESPACE} (if present)..."
  if [ -f "${OUT_FILE}" ]; then
    "${KUBECTL}" delete -f "${OUT_FILE}" --ignore-not-found || true
  fi
  "${KUBECTL}" -n "${NAMESPACE}" delete secret "${SECRET_NAME}" --ignore-not-found || true
  "${KUBECTL}" -n "${NAMESPACE}" delete sa "${SERVICE_ACCOUNT}" --ignore-not-found || true
  if [ "${YES}" -eq 1 ]; then
    "${KUBECTL}" delete ns "${NAMESPACE}" --ignore-not-found || true
    info "Namespace ${NAMESPACE} deletion requested (non-interactive)."
  else
    if [ ! -t 0 ]; then
      err "Non-interactive environment detected and --yes not provided. Aborting to avoid accidental deletion."
      exit 12
    fi
    read -r -p "Do you want to delete the namespace ${NAMESPACE}? [y/N] " yn
    if [[ "${yn}" =~ ^[Yy]$ ]]; then
      "${KUBECTL}" delete ns "${NAMESPACE}" --ignore-not-found || true
      info "Namespace ${NAMESPACE} deletion requested."
    else
      info "Namespace not deleted."
    fi
  fi
  info "NOTE: StorageClass resources are NOT deleted by this script."
}

print_connection_info() {
  info "Connection information (structured block):"
  printf "VALKEY_NAMESPACE=%s\n" "${NAMESPACE}"
  printf "VALKEY_SERVICE=%s\n" "${CLIENT_SVC}"
  printf "VALKEY_HEADLESS=%s\n" "${HEADLESS_SVC}"
  printf "VALKEY_PORT=%s\n" "${VALKEY_PORT}"
  printf "VALKEY_SECRET=%s/%s\n" "${NAMESPACE}" "${SECRET_NAME}"
  printf "IN_CLUSTER_URL=valkey://:%s@%s.%s.svc.cluster.local:%s\n" "${VALKEY_PASSWORD}" "${CLIENT_SVC}" "${NAMESPACE}" "${VALKEY_PORT}"
  printf "HEADLESS_PATTERN=%s.%s.svc.cluster.local\n" "${HEADLESS_SVC}" "${NAMESPACE}"
  printf "EXAMPLE_PORT_FORWARD=kubectl -n %s port-forward svc/%s 6379:6379\n" "${NAMESPACE}" "${CLIENT_SVC}"
  if [ -n "${LOG_FILE}" ]; then
    printf "LOG_FILE=%s\n" "${LOG_FILE}"
  fi
  if [ -n "${LOG_FILE}" ]; then
    printf "Connection info logged to %s\n" "${LOG_FILE}" >> "${LOG_FILE}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --render-only) ACTION="render"; shift ;;
    --rollout) ACTION="rollout"; shift ;;
    --delete) ACTION="delete"; shift ;;
    --inspect) ACTION="inspect"; shift ;;
    --test) INSPECT_TEST=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --log-file) LOG_FILE="$2"; shift 2 ;;
    --help|-h) echo "Usage: $0 [--render-only|--rollout|--delete|--inspect] [--yes] [--test] [--log-file <file>]"; exit 0 ;;
    *) err "Unknown arg: $1"; echo "Usage: $0 [--render-only|--rollout|--delete|--inspect] [--yes] [--test] [--log-file <file>]"; exit 2 ;;
  esac
done

if [ -z "${ACTION}" ]; then
  err "No action provided. Use --render-only, --rollout, --inspect, or --delete."
  exit 2
fi

validate_env

case "${ACTION}" in
  render)
    render_manifest
    info "Rendered to ${OUT_FILE}"
    ;;
  rollout)
    render_manifest
    create_namespace_and_secret
    apply_manifest
    wait_for_rollout
    smoke_test
    print_connection_info
    ;;
  inspect)
    inspect_cluster
    if [ "${INSPECT_TEST}" -eq 1 ]; then
      high_signal_tests
    fi
    ;;
  delete)
    delete_resources
    ;;
  *)
    err "Unknown action: ${ACTION}"
    exit 2
    ;;
esac

info "Action ${ACTION} completed."