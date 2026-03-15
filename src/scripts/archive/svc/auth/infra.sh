#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# src/services/auth/infra.sh
# Platform-grade idempotent controller for auth service manifests.
# Commands: --rollout | --inspect | --delete
# Secrets are created/updated via kubectl (not by applying templates that contain unsubstituted placeholders).

MANIFESTS_DIR="${MANIFESTS_DIR:-src/manifests/auth}"
K8S_CLUSTER="${K8S_CLUSTER:-kind}"           # kind | eks
AUTH_NAMESPACE="${AUTH_NAMESPACE:-app}"
AUTH_IMAGE="${AUTH_IMAGE:-athithya5354/agentops-auth:multiarch-v0.2}"
AUTH_NAME="${AUTH_NAME:-auth}"

# node selection for EKS inference nodegroup (applied only when K8S_CLUSTER=eks)
INFERENCE_NODE_LABEL_KEY="${INFERENCE_NODE_LABEL_KEY:-nodegroup}"
INFERENCE_NODE_LABEL_VALUE="${INFERENCE_NODE_LABEL_VALUE:-inference}"

# Secrets / inputs (can be provided via environment)
DATABASE_URL="${DATABASE_URL:-}"
JWT_SECRET="${JWT_SECRET:-}"
JWT_SECRET_PREVIOUS="${JWT_SECRET}"
SESSION_SECRET="${SESSION_SECRET:-}"
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}"
GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"
MICROSOFT_CLIENT_ID="${MICROSOFT_CLIENT_ID:-}"
MICROSOFT_CLIENT_SECRET="${MICROSOFT_CLIENT_SECRET:-}"

AUTH_BASE_URL="${AUTH_BASE_URL:-}"
JWT_EXP_SECONDS="${JWT_EXP_SECONDS:-1800}"
JWT_ISS="${JWT_ISS:-agentic-platform}"
JWT_AUD="${JWT_AUD:-agent-frontend}"

GOOGLE_ALLOWED_DOMAINS="${GOOGLE_ALLOWED_DOMAINS:-}"
MICROSOFT_ALLOWED_DOMAINS="${MICROSOFT_ALLOWED_DOMAINS:-}"
MICROSOFT_ALLOWED_TENANT_IDS="${MICROSOFT_ALLOWED_TENANT_IDS:-}"

SESSION_COOKIE_NAME="${SESSION_COOKIE_NAME:-auth_session}"
SESSION_COOKIE_SECURE="${SESSION_COOKIE_SECURE:-false}"
SESSION_COOKIE_SAMESITE="${SESSION_COOKIE_SAMESITE:-lax}"
SESSION_COOKIE_DOMAIN="${SESSION_COOKIE_DOMAIN:-}"
SESSION_COOKIE_MAX_AGE="${SESSION_COOKIE_MAX_AGE:-3600}"
PKCE_TTL_SECONDS="${PKCE_TTL_SECONDS:-300}"

# Postgres secret info (used to derive DATABASE_URL when it's not provided)
POSTGRES_SECRET_NAME="${POSTGRES_SECRET_NAME:-app-postgres-app}"
POSTGRES_NAMESPACE="${POSTGRES_NAMESPACE:-databases}"
POSTGRES_HOST="${POSTGRES_HOST:-app-postgres-r.databases.svc.cluster.local}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-app}"
POSTGRES_USER="${POSTGRES_USER:-app}"

# HPA / replica defaults (different defaults for kind vs eks)
if [[ "${K8S_CLUSTER}" == "eks" ]]; then
  REPLICAS=2
  MIN_REPLICAS=2
  MAX_REPLICAS=6
  CPU_TARGET=60
else
  REPLICAS=1
  MIN_REPLICAS=1
  MAX_REPLICAS=2
  CPU_TARGET=70
fi

LOG(){ printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >&2; }
FATAL(){ LOG "FATAL: $*"; exit 1; }
require_bin(){ command -v "$1" >/dev/null 2>&1 || FATAL "$1 not found in PATH"; }

# Parse flags
MODE="render-only"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rollout) MODE="rollout"; shift ;;
    --inspect) MODE="inspect"; shift ;;
    --delete) MODE="delete"; shift ;;
    --help|-h) printf "Usage: %s [--rollout|--inspect|--delete]\n" "$0"; exit 0 ;;
    *) FATAL "Unknown arg: $1" ;;
  esac
done

require_bin mkdir
require_bin kubectl
require_bin sed
require_bin awk
require_bin printf
require_bin base64

mkdir -p "${MANIFESTS_DIR}"

render_templates(){
  LOG "Rendering manifests to ${MANIFESTS_DIR} (K8S_CLUSTER=${K8S_CLUSTER})"

  # secret.template.yaml: safe placeholder file intended for git (NOT applied by kustomize)
  cat > "${MANIFESTS_DIR}/secret.template.yaml" <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: auth-secrets
  namespace: ${AUTH_NAMESPACE}
  labels:
    app.kubernetes.io/name: auth
    app.kubernetes.io/managed-by: infra-generator
type: Opaque
stringData:
  # Provide either database-url (preferred) OR supply runtime secret via kubectl create secret
  database-url: "${DATABASE_URL:-}"
  jwt-secret: "${JWT_SECRET:-}"
  jwt-secret-previous: "${JWT_SECRET_PREVIOUS:-}"
  session-secret: "${SESSION_SECRET:-}"
  google-client-id: "${GOOGLE_CLIENT_ID:-}"
  google-client-secret: "${GOOGLE_CLIENT_SECRET:-}"
  microsoft-client-id: "${MICROSOFT_CLIENT_ID:-}"
  microsoft-client-secret: "${MICROSOFT_CLIENT_SECRET:-}"
EOF

  # configmap.template.yaml - non-sensitive configs
  cat > "${MANIFESTS_DIR}/configmap.template.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: auth-config
  namespace: ${AUTH_NAMESPACE}
  labels:
    app.kubernetes.io/name: auth
    app.kubernetes.io/managed-by: infra-generator
data:
  AUTH_BASE_URL: "${AUTH_BASE_URL}"
  JWT_EXP_SECONDS: "${JWT_EXP_SECONDS}"
  JWT_ISS: "${JWT_ISS}"
  JWT_AUD: "${JWT_AUD}"
  GOOGLE_ALLOWED_DOMAINS: "${GOOGLE_ALLOWED_DOMAINS}"
  MICROSOFT_ALLOWED_DOMAINS: "${MICROSOFT_ALLOWED_DOMAINS}"
  MICROSOFT_ALLOWED_TENANT_IDS: "${MICROSOFT_ALLOWED_TENANT_IDS}"
  SESSION_COOKIE_NAME: "${SESSION_COOKIE_NAME}"
  SESSION_COOKIE_SECURE: "${SESSION_COOKIE_SECURE}"
  SESSION_COOKIE_SAMESITE: "${SESSION_COOKIE_SAMESITE}"
  SESSION_COOKIE_DOMAIN: "${SESSION_COOKIE_DOMAIN}"
  SESSION_COOKIE_MAX_AGE: "${SESSION_COOKIE_MAX_AGE}"
  PKCE_TTL_SECONDS: "${PKCE_TTL_SECONDS}"
EOF

  # Service
  cat > "${MANIFESTS_DIR}/service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${AUTH_NAME}
  namespace: ${AUTH_NAMESPACE}
  labels:
    app: ${AUTH_NAME}
spec:
  type: ClusterIP
  selector:
    app: ${AUTH_NAME}
  ports:
    - name: http
      port: 80
      targetPort: 8080
EOF

  # ServiceAccount
  cat > "${MANIFESTS_DIR}/serviceaccount.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${AUTH_NAME}
  namespace: ${AUTH_NAMESPACE}
  labels:
    app: ${AUTH_NAME}
EOF

  # Build optional nodeSelector YAML snippet (empty for non-eks)
  NODE_SELECTOR_YAML=""
  if [[ "${K8S_CLUSTER}" == "eks" ]]; then
    NODE_SELECTOR_YAML="$(printf '      nodeSelector:\n        %s: \"%s\"\n' "${INFERENCE_NODE_LABEL_KEY}" "${INFERENCE_NODE_LABEL_VALUE}")"
  fi

  # Deployment (uses only secretKeyRef for sensitive values). Node selector included only for eks.
  cat > "${MANIFESTS_DIR}/deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${AUTH_NAME}
  namespace: ${AUTH_NAMESPACE}
  labels:
    app: ${AUTH_NAME}
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: ${AUTH_NAME}
  template:
    metadata:
      labels:
        app: ${AUTH_NAME}
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
    spec:
${NODE_SELECTOR_YAML}      serviceAccountName: ${AUTH_NAME}
      terminationGracePeriodSeconds: 30
      containers:
        - name: ${AUTH_NAME}
          image: ${AUTH_IMAGE}
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
              name: http
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: auth-secrets
                  key: database-url
            - name: JWT_SECRET
              valueFrom:
                secretKeyRef:
                  name: auth-secrets
                  key: jwt-secret
            - name: JWT_SECRET_PREVIOUS
              valueFrom:
                secretKeyRef:
                  name: auth-secrets
                  key: jwt-secret-previous
            - name: SESSION_SECRET
              valueFrom:
                secretKeyRef:
                  name: auth-secrets
                  key: session-secret
            - name: GOOGLE_CLIENT_ID
              valueFrom:
                secretKeyRef:
                  name: auth-secrets
                  key: google-client-id
            - name: GOOGLE_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: auth-secrets
                  key: google-client-secret
            - name: MICROSOFT_CLIENT_ID
              valueFrom:
                secretKeyRef:
                  name: auth-secrets
                  key: microsoft-client-id
            - name: MICROSOFT_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: auth-secrets
                  key: microsoft-client-secret
            - name: AUTH_BASE_URL
              valueFrom:
                configMapKeyRef:
                  name: auth-config
                  key: AUTH_BASE_URL
            - name: JWT_EXP_SECONDS
              valueFrom:
                configMapKeyRef:
                  name: auth-config
                  key: JWT_EXP_SECONDS
            - name: JWT_ISS
              valueFrom:
                configMapKeyRef:
                  name: auth-config
                  key: JWT_ISS
            - name: JWT_AUD
              valueFrom:
                configMapKeyRef:
                  name: auth-config
                  key: JWT_AUD
            - name: GOOGLE_ALLOWED_DOMAINS
              valueFrom:
                configMapKeyRef:
                  name: auth-config
                  key: GOOGLE_ALLOWED_DOMAINS
            - name: MICROSOFT_ALLOWED_DOMAINS
              valueFrom:
                configMapKeyRef:
                  name: auth-config
                  key: MICROSOFT_ALLOWED_DOMAINS
            - name: MICROSOFT_ALLOWED_TENANT_IDS
              valueFrom:
                configMapKeyRef:
                  name: auth-config
                  key: MICROSOFT_ALLOWED_TENANT_IDS
            - name: SESSION_COOKIE_NAME
              valueFrom:
                configMapKeyRef:
                  name: auth-config
                  key: SESSION_COOKIE_NAME
            - name: SESSION_COOKIE_SECURE
              valueFrom:
                configMapKeyRef:
                  name: auth-config
                  key: SESSION_COOKIE_SECURE
            - name: SESSION_COOKIE_SAMESITE
              valueFrom:
                configMapKeyRef:
                  name: auth-config
                  key: SESSION_COOKIE_SAMESITE
            - name: SESSION_COOKIE_DOMAIN
              valueFrom:
                configMapKeyRef:
                  name: auth-config
                  key: SESSION_COOKIE_DOMAIN
            - name: SESSION_COOKIE_MAX_AGE
              valueFrom:
                configMapKeyRef:
                  name: auth-config
                  key: SESSION_COOKIE_MAX_AGE
            - name: PKCE_TTL_SECONDS
              valueFrom:
                configMapKeyRef:
                  name: auth-config
                  key: PKCE_TTL_SECONDS
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 20
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          resources:
            requests:
              cpu: "200m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: "kubernetes.io/hostname"
                labelSelector:
                  matchLabels:
                    app: ${AUTH_NAME}
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: "kubernetes.io/hostname"
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: ${AUTH_NAME}
EOF

  # HPA
  cat > "${MANIFESTS_DIR}/hpa.yaml" <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${AUTH_NAME}
  namespace: ${AUTH_NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${AUTH_NAME}
  minReplicas: ${MIN_REPLICAS}
  maxReplicas: ${MAX_REPLICAS}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: ${CPU_TARGET}
EOF

  # kustomization: IMPORTANT: do NOT include secret.template.yaml here (it is a safe-to-commit placeholder)
  cat > "${MANIFESTS_DIR}/kustomization.yaml" <<EOF
resources:
  - configmap.template.yaml
  - serviceaccount.yaml
  - service.yaml
  - deployment.yaml
  - hpa.yaml
namespace: ${AUTH_NAMESPACE}
EOF

  LOG "Manifests rendered: $(ls -1 "${MANIFESTS_DIR}" | tr '\n' ' ' )"
}

# try to derive DATABASE_URL from postgres secret if DATABASE_URL not supplied
derive_database_url(){
  if [[ -n "${DATABASE_URL}" ]]; then
    LOG "Using provided DATABASE_URL"
    return 0
  fi

  LOG "DATABASE_URL not supplied; attempting derive from secret ${POSTGRES_SECRET_NAME} in ${POSTGRES_NAMESPACE}"
  if ! kubectl -n "${POSTGRES_NAMESPACE}" get secret "${POSTGRES_SECRET_NAME}" >/dev/null 2>&1; then
    LOG "Postgres secret ${POSTGRES_SECRET_NAME} not found; leave DATABASE_URL empty"
    return 0
  fi

  # common key name "password"
  local pass_b64
  pass_b64="$(kubectl -n "${POSTGRES_NAMESPACE}" get secret "${POSTGRES_SECRET_NAME}" -o jsonpath='{.data.password}' 2>/dev/null || true)"
  if [[ -z "${pass_b64}" ]]; then
    LOG "Postgres secret present but no 'password' key; skip derive"
    return 0
  fi

  local pass
  pass="$(printf "%s" "${pass_b64}" | base64 --decode)"
  DATABASE_URL="postgresql://${POSTGRES_USER}:${pass}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
  LOG "Derived DATABASE_URL (host=${POSTGRES_HOST}, user=${POSTGRES_USER})"
}

# create/update auth-secrets from concrete values (idempotent). If no values provided, just skip.
ensure_auth_secret(){
  local args=()
  if [[ -n "${DATABASE_URL}" ]]; then
    args+=(--from-literal=database-url="${DATABASE_URL}")
  fi
  [[ -n "${JWT_SECRET}" ]] && args+=(--from-literal=jwt-secret="${JWT_SECRET}")
  [[ -n "${JWT_SECRET_PREVIOUS}" ]] && args+=(--from-literal=jwt-secret-previous="${JWT_SECRET_PREVIOUS}")
  [[ -n "${SESSION_SECRET}" ]] && args+=(--from-literal=session-secret="${SESSION_SECRET}")
  [[ -n "${GOOGLE_CLIENT_ID}" ]] && args+=(--from-literal=google-client-id="${GOOGLE_CLIENT_ID}")
  [[ -n "${GOOGLE_CLIENT_SECRET}" ]] && args+=(--from-literal=google-client-secret="${GOOGLE_CLIENT_SECRET}")
  [[ -n "${MICROSOFT_CLIENT_ID}" ]] && args+=(--from-literal=microsoft-client-id="${MICROSOFT_CLIENT_ID}")
  [[ -n "${MICROSOFT_CLIENT_SECRET}" ]] && args+=(--from-literal=microsoft-client-secret="${MICROSOFT_CLIENT_SECRET}")

  if [[ ${#args[@]} -eq 0 ]]; then
    LOG "No concrete secret values provided; skipping creation of auth-secrets (manifests still reference it)."
    return 0
  fi

  LOG "Creating/updating secret auth-secrets in namespace ${AUTH_NAMESPACE}"
  kubectl create secret generic auth-secrets -n "${AUTH_NAMESPACE}" "${args[@]}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  LOG "auth-secrets created/updated"
}

# diff and apply idempotent
diff_and_apply(){
  LOG "Performing diff: kubectl diff -k ${MANIFESTS_DIR}"
  tmpdiff="$(mktemp)"
  set +e
  kubectl diff -k "${MANIFESTS_DIR}" >"${tmpdiff}" 2>&1
  diff_rc=$?
  set -e

  if [[ ${diff_rc} -eq 0 ]]; then
    # diff command succeeded and returned 0 => no differences
    if [[ -s "${tmpdiff}" ]]; then
      LOG "kubectl diff returned 0 but output present; treating as no-change (unexpected)."
      rm -f "${tmpdiff}"
      return 2
    fi
    rm -f "${tmpdiff}"
    LOG "No changes detected; skipping apply."
    return 2
  fi

  # diff_rc != 0 : could be diff produced (normal) or error. Inspect output for server errors.
  if grep -q "Error from server" "${tmpdiff}" 2>/dev/null; then
    LOG "kubectl diff encountered server error; printing first lines of output for diagnosis"
    sed -n '1,200p' "${tmpdiff}" >&2
    rm -f "${tmpdiff}"
    return 1
  fi

  # treat diff output as changes -> apply
  LOG "Changes detected; applying manifests"
  rm -f "${tmpdiff}"
  if ! kubectl apply -k "${MANIFESTS_DIR}" >/dev/null 2>&1; then
    LOG "kubectl apply failed; attempting to gather diagnostics"
    kubectl -n "${AUTH_NAMESPACE}" get pods -o wide || true
    kubectl -n "${AUTH_NAMESPACE}" logs -l app="${AUTH_NAME}" --tail=200 || true
    return 1
  fi
  return 0
}

wait_deployment_available(){
  LOG "Waiting for deployment/${AUTH_NAME} available in ${AUTH_NAMESPACE} (timeout 180s)"
  if ! kubectl -n "${AUTH_NAMESPACE}" wait --for=condition=available --timeout=180s deployment/"${AUTH_NAME}"; then
    LOG "Deployment did not become available in time; collecting diagnostics"
    kubectl -n "${AUTH_NAMESPACE}" get pods -o wide || true
    kubectl -n "${AUTH_NAMESPACE}" describe deployment "${AUTH_NAME}" || true
    kubectl -n "${AUTH_NAMESPACE}" logs -l app="${AUTH_NAME}" --tail=200 || true
    return 1
  fi
  LOG "Deployment is available"
  return 0
}

inspect(){
  LOG "=== INSPECT MODE ==="
  LOG "Namespace: ${AUTH_NAMESPACE}"
  kubectl get ns "${AUTH_NAMESPACE}" --ignore-not-found -o wide || true
  LOG "Deployment / Pods"
  kubectl -n "${AUTH_NAMESPACE}" get deploy,sts,po -l app="${AUTH_NAME}" -o wide || true

  LOG "Secret auth-secrets (masked)"
  if kubectl -n "${AUTH_NAMESPACE}" get secret auth-secrets >/dev/null 2>&1; then
    local db64
    db64="$(kubectl -n "${AUTH_NAMESPACE}" get secret auth-secrets -o jsonpath='{.data.database-url}' 2>/dev/null || true)"
    if [[ -n "${db64}" ]]; then
      printf "%s\n" "${db64}" | base64 --decode 2>/dev/null | sed -E 's,(postgresql://[^:]+:)[^@]+(@),\1****\2,' || true
    else
      LOG "(database-url not set in auth-secrets)"
    fi
  else
    LOG "(auth-secrets not present)"
  fi

  LOG "Service"
  kubectl -n "${AUTH_NAMESPACE}" get svc "${AUTH_NAME}" --ignore-not-found -o wide || true
  LOG "ConfigMap auth-config"
  kubectl -n "${AUTH_NAMESPACE}" get configmap auth-config --ignore-not-found -o yaml || true
  LOG "=== END INSPECT ==="
}

delete(){
  LOG "Deleting kustomize-managed resources"
  kubectl -n "${AUTH_NAMESPACE}" delete -k "${MANIFESTS_DIR}" --ignore-not-found || true
  LOG "Deleting secret auth-secrets (if exists)"
  kubectl -n "${AUTH_NAMESPACE}" delete secret auth-secrets --ignore-not-found || true
  LOG "Note: namespace ${AUTH_NAMESPACE} is retained by default."
}

# Main driver
render_templates

case "${MODE}" in
  rollout)
    LOG "Starting rollout (idempotent) for ${AUTH_NAME} in ${AUTH_NAMESPACE}"
    kubectl create namespace "${AUTH_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

    derive_database_url
    ensure_auth_secret

    diff_and_apply
    rc=$?
    if [[ ${rc} -eq 2 ]]; then
      LOG "No manifest changes detected; skipping apply (no restarts)."
      inspect
      exit 0
    elif [[ ${rc} -ne 0 ]]; then
      FATAL "Apply failed"
    fi

    wait_deployment_available || FATAL "Deployment did not reach available state after apply"
    LOG "Rollout success"
    inspect
    ;;

  inspect)
    inspect
    ;;

  delete)
    delete
    ;;

  *)
    LOG "Render-only mode; manifests written to ${MANIFESTS_DIR}"
    LOG "To perform rollout: $0 --rollout"
    ;;
esac

exit 0