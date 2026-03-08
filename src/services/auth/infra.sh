#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# src/services/auth/infra.sh
# Platform-grade, idempotent manifest generator + controller for the auth service.
# Features:
#  - Renders manifests to src/manifests/auth (safe templates for git)
#  - Creates/updates cluster secret 'auth-secrets' from env values or auto-extracted Postgres secret
#  - Commands: --rollout (idempotent apply/diff), --inspect, --delete
#  - For --rollout: will diff; if no change, nothing applied (pods not restarted). If changes, applies and waits for deployment.
#  - Uses a single DATABASE_URL secret value for DB connectivity (avoids fragmented DB env vars).
#  - Supports K8S_CLUSTER=kind or eks; adds nodeSelector for EKS inference nodegroup.
#  - All sensitive values are sourced into secret 'auth-secrets' (not committed).
#
# Usage:
#   K8S_CLUSTER=kind AUTH_NAMESPACE=app AUTH_IMAGE=ghcr.io/yourorg/auth:tag ./src/services/auth/infra.sh --rollout
#   ./src/services/auth/infra.sh --inspect
#   ./src/services/auth/infra.sh --delete
#
# ENV (selected):
#   K8S_CLUSTER            kind|eks (default: kind)
#   AUTH_NAMESPACE         namespace to install to (default: app)
#   AUTH_IMAGE             container image (default placeholder)
#   DATABASE_URL           full postgres URI (preferred). If omitted script will attempt to derive from known postgres secret.
#   JWT_SECRET, SESSION_SECRET, GOOGLE_CLIENT_ID/SECRET, etc. (optional, used to create auth-secrets)
#   INFERENCE_NODE_LABEL_KEY/VAL used for nodeSelector on eks
#
# Exit codes:
#   0 success, non-zero on fatal errors

MANIFESTS_DIR="${MANIFESTS_DIR:-src/manifests/auth}"
K8S_CLUSTER="${K8S_CLUSTER:-kind}"
AUTH_NAMESPACE="${AUTH_NAMESPACE:-app}"
AUTH_IMAGE="${AUTH_IMAGE:-athithya5354/agentops-auth:multiarch-v0.2}"
AUTH_NAME="${AUTH_NAME:-auth}"
INFERENCE_NODE_LABEL_KEY="${INFERENCE_NODE_LABEL_KEY:-nodegroup}"
INFERENCE_NODE_LABEL_VALUE="${INFERENCE_NODE_LABEL_VALUE:-inference}"

# Secrets / config inputs (supply via env)
DATABASE_URL="${DATABASE_URL:-}"
JWT_SECRET="${JWT_SECRET:-}"
JWT_SECRET_PREVIOUS="${JWT_SECRET_PREVIOUS:-}"
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

# Auto-detected Postgres secret, host used when DATABASE_URL not supplied
POSTGRES_SECRET_NAME="${POSTGRES_SECRET_NAME:-app-postgres-app}"    # produced by postgres rollout
POSTGRES_NAMESPACE="${POSTGRES_NAMESPACE:-databases}"
POSTGRES_HOST="${POSTGRES_HOST:-app-postgres-r.databases.svc.cluster.local}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-app}"
POSTGRES_USER="${POSTGRES_USER:-app}"

# HPA / replica defaults
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

# parse flags
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
require_bin awk
require_bin sed
require_bin printf

mkdir -p "${MANIFESTS_DIR}"

render_templates(){
  LOG "Rendering manifests to ${MANIFESTS_DIR} (K8S_CLUSTER=${K8S_CLUSTER})"

  # secret.template.yaml - placeholders only (safe to commit)
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
  # Provide either database-url (preferred) OR db-user/db-password etc (not recommended).
  database-url: "${DATABASE_URL:-}"
  jwt-secret: "${JWT_SECRET:-}"
  jwt-secret-previous: "${JWT_SECRET_PREVIOUS:-}"
  session-secret: "${SESSION_SECRET:-}"
  google-client-id: "${GOOGLE_CLIENT_ID:-}"
  google-client-secret: "${GOOGLE_CLIENT_SECRET:-}"
  microsoft-client-id: "${MICROSOFT_CLIENT_ID:-}"
  microsoft-client-secret: "${MICROSOFT_CLIENT_SECRET:-}"
EOF

  # configmap.template.yaml (non-sensitive)
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

  cat > "${MANIFESTS_DIR}/serviceaccount.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${AUTH_NAME}
  namespace: ${AUTH_NAMESPACE}
  labels:
    app: ${AUTH_NAME}
EOF

  # deployment (env wiring uses only DATABASE_URL secret)
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
      serviceAccountName: ${AUTH_NAME}
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

  # add nodeSelector for EKS clusters to prefer inference nodegroup
  if [[ "${K8S_CLUSTER}" == "eks" ]]; then
    awk -v key="${INFERENCE_NODE_LABEL_KEY}" -v val="${INFERENCE_NODE_LABEL_VALUE}" '
      /topologySpreadConstraints:/ { print; inblock=1; next }
      { print }
      END { if (inblock) print "      nodeSelector:\n        " key ": \"" val "\"\n" }
    ' "${MANIFESTS_DIR}/deployment.yaml" > "${MANIFESTS_DIR}/deployment.tmp" && mv "${MANIFESTS_DIR}/deployment.tmp" "${MANIFESTS_DIR}/deployment.yaml"
    LOG "Added nodeSelector: ${INFERENCE_NODE_LABEL_KEY}=${INFERENCE_NODE_LABEL_VALUE}"
  fi

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

  cat > "${MANIFESTS_DIR}/kustomization.yaml" <<EOF
resources:
  - secret.template.yaml
  - configmap.template.yaml
  - serviceaccount.yaml
  - service.yaml
  - deployment.yaml
  - hpa.yaml
namespace: ${AUTH_NAMESPACE}
EOF

  LOG "Manifests rendered: $(ls -1 ${MANIFESTS_DIR} | sed -n '1,200p' )"
}

# Attempt to auto-derive DATABASE_URL from postgres secret if DATABASE_URL not provided
derive_database_url(){
  if [[ -n "${DATABASE_URL}" ]]; then
    LOG "DATABASE_URL supplied via env - using it."
    return 0
  fi

  LOG "DATABASE_URL not supplied. Attempting to derive from Postgres secret ${POSTGRES_SECRET_NAME} in namespace ${POSTGRES_NAMESPACE}."

  if ! kubectl -n "${POSTGRES_NAMESPACE}" get secret "${POSTGRES_SECRET_NAME}" >/dev/null 2>&1; then
    LOG "Postgres secret ${POSTGRES_SECRET_NAME} not found in namespace ${POSTGRES_NAMESPACE}. Skipping auto-derive."
    return 0
  fi

  # Try common secret keys: password
  local pass_b64
  pass_b64="$(kubectl -n "${POSTGRES_NAMESPACE}" get secret "${POSTGRES_SECRET_NAME}" -o jsonpath='{.data.password}' 2>/dev/null || true)"
  if [[ -z "${pass_b64}" ]]; then
    LOG "Secret ${POSTGRES_SECRET_NAME} exists but no 'password' field found; skipping derive."
    return 0
  fi

  local pass
  pass="$(printf "%s" "${pass_b64}" | base64 --decode)"
  DATABASE_URL="postgresql://${POSTGRES_USER}:${pass}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
  LOG "Derived DATABASE_URL from ${POSTGRES_SECRET_NAME} (host=${POSTGRES_HOST}, user=${POSTGRES_USER})."
}

# Create or update auth-secrets if concrete values available
ensure_auth_secret(){
  # Build args for kubectl create secret generic
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
    LOG "No concrete secret values provided to create auth-secrets (skip). Manifests still reference auth-secrets (use kubectl create secret to provide values)."
    return 0
  fi

  LOG "Creating/updating auth-secrets in namespace ${AUTH_NAMESPACE} (idempotent)"
  kubectl create secret generic auth-secrets -n "${AUTH_NAMESPACE}" "${args[@]}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  LOG "auth-secrets created/updated"
}

# Diff then apply (idempotent rollout)
diff_and_apply(){
  LOG "Performing diff: kubectl diff -k ${MANIFESTS_DIR} (server-side)"
  if kubectl diff -k "${MANIFESTS_DIR}" >/tmp/auth.diff 2>&1; then
    if [[ -s /tmp/auth.diff ]]; then
      LOG "Changes detected (diff non-empty). Applying manifests."
      kubectl apply -k "${MANIFESTS_DIR}" || { LOG "kubectl apply failed"; return 1; }
      return 0
    else
      LOG "No changes detected (diff empty). Skipping apply."
      return 2
    fi
  else
    # kubectl diff returns non-zero on diff or errors; inspect output
    if grep -q "Error from server" /tmp/auth.diff 2>/dev/null; then
      LOG "kubectl diff encountered server error - showing output"
      sed -n '1,200p' /tmp/auth.diff >&2
      return 1
    fi
    # non-empty diff (diff outputs to stdout but exitcode non-zero) treat as changes
    if [[ -s /tmp/auth.diff ]]; then
      LOG "Diff command produced output (treating as changes). Applying."
      sed -n '1,200p' /tmp/auth.diff >&2
      kubectl apply -k "${MANIFESTS_DIR}" || { LOG "kubectl apply failed"; return 1; }
      return 0
    fi
    LOG "kubectl diff returned non-zero with no diff output; attempting apply."
    kubectl apply -k "${MANIFESTS_DIR}" || { LOG "kubectl apply failed"; return 1; }
    return 0
  fi
}

wait_deployment_available(){
  LOG "Waiting for deployment/${AUTH_NAME} available in ${AUTH_NAMESPACE} (timeout 180s)"
  if ! kubectl -n "${AUTH_NAMESPACE}" wait --for=condition=available --timeout=180s deployment/${AUTH_NAME}; then
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
  LOG "Secrets referencing"
  kubectl -n "${AUTH_NAMESPACE}" get secret auth-secrets --ignore-not-found -o yaml || true
  if kubectl -n "${AUTH_NAMESPACE}" get secret auth-secrets >/dev/null 2>&1; then
    LOG "DATABASE_URL (masked):"
    kubectl -n "${AUTH_NAMESPACE}" get secret auth-secrets -o jsonpath='{.data.database-url}' 2>/dev/null | sed -n '1p' | { read -r db64 || true; if [[ -n "${db64}" ]]; then printf "%s\n" "${db64}" | base64 --decode | sed -E 's/(\/\/[^:]+:).+(@)/\1****\2/'; else echo "(not set)"; fi; }
  fi
  LOG "Service"
  kubectl -n "${AUTH_NAMESPACE}" get svc "${AUTH_NAME}" --ignore-not-found -o wide || true
  LOG "ConfigMap auth-config"
  kubectl -n "${AUTH_NAMESPACE}" get configmap auth-config --ignore-not-found -o yaml || true
  LOG "=== END INSPECT ==="
}

delete(){
  LOG "Deleting kustomize resources in ${MANIFESTS_DIR} (kubectl delete -k)"
  if kubectl -n "${AUTH_NAMESPACE}" get deployment "${AUTH_NAME}" >/dev/null 2>&1; then
    kubectl delete -k "${MANIFESTS_DIR}" --ignore-not-found || true
    LOG "Deleted resources from kustomize"
  else
    LOG "Deployment ${AUTH_NAME} not present; still attempting to delete resources"
    kubectl delete -k "${MANIFESTS_DIR}" --ignore-not-found || true
  fi

  LOG "Deleting secret auth-secrets in namespace ${AUTH_NAMESPACE} (if exists)"
  kubectl -n "${AUTH_NAMESPACE}" delete secret auth-secrets --ignore-not-found || true

  LOG "Note: namespace ${AUTH_NAMESPACE} retained. If you want to remove the namespace, run: kubectl delete ns ${AUTH_NAMESPACE}"
}

# Main driver
render_templates

case "${MODE}" in
  rollout)
    LOG "Starting rollout (idempotent) for ${AUTH_NAME} in ${AUTH_NAMESPACE}"
    # ensure namespace exists
    kubectl create namespace "${AUTH_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
    derive_database_url
    ensure_auth_secret

    # perform diff+apply idempotently
    diff_and_apply
    rc=$?
    if [[ ${rc} -eq 2 ]]; then
      LOG "No manifest changes detected; skipping rollout (no restarts)."
      inspect
      exit 0
    elif [[ ${rc} -ne 0 ]]; then
      FATAL "Apply failed"
    fi

    # Applied changes; wait for deployment
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
    LOG "Render-only mode; manifests are written to ${MANIFESTS_DIR}"
    LOG "To perform rollout: $0 --rollout"
    ;;
esac

exit 0