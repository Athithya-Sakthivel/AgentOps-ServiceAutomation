#!/usr/bin/env bash
set -euo pipefail

# === CONFIGURATION ===
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MANIFEST_DIR="${SCRIPT_DIR}/../manifests/postgres"
readonly ARCHIVE_DIR="${SCRIPT_DIR}/../archive"
readonly K8S_CLUSTER="${K8S_CLUSTER:-kind}"

# === STRONG DEFAULTS (Must match default_storage_class.sh) ===
declare -A STORAGE_CLASS=( [kind]="local-path" [eks]="gp3" )
declare -A PG_INSTANCES=( [kind]="1" [eks]="3" )
declare -A PG_STORAGE_SIZE=( [kind]="5Gi" [eks]="20Gi" )
declare -A PG_CPU_REQUEST=( [kind]="250m" [eks]="500m" )
declare -A PG_MEMORY_REQUEST=( [kind]="512Mi" [eks]="1Gi" )
declare -A PG_CPU_LIMIT=( [kind]="500m" [eks]="1" )
declare -A PG_MEMORY_LIMIT=( [kind]="1Gi" [eks]="2Gi" )
declare -A OPERATOR_TIMEOUT=( [kind]="120" [eks]="300" )
declare -A CLUSTER_WAIT_TIMEOUT=( [kind]="300" [eks]="900" )

# === VALIDATION ===
if [[ ! "${STORAGE_CLASS[$K8S_CLUSTER]+isset}" ]]; then
  echo "[ERROR] Unsupported K8S_CLUSTER='$K8S_CLUSTER'. Supported: kind, eks" >&2
  exit 1
fi

# === LOGGING ===
log() { printf '[%s] [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$K8S_CLUSTER" "$*" >&2; }
fatal() { printf '[ERROR] [%s] %s\n' "$K8S_CLUSTER" "$*" >&2; exit 1; }
require_bin() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"; }

# === RENDER MANIFESTS ===
render_manifests() {
  log "rendering manifests for K8S_CLUSTER=$K8S_CLUSTER"
  mkdir -p "${MANIFEST_DIR}"
  
  cat > "${MANIFEST_DIR}/namespaces.yaml" <<'EOFNS'
apiVersion: v1
kind: Namespace
metadata:
  name: databases
---
apiVersion: v1
kind: Namespace
metadata:
  name: apps
  labels:
    db-access: "allow"
---
apiVersion: v1
kind: Namespace
metadata:
  name: ray
  labels:
    db-access: "allow"
---
apiVersion: v1
kind: Namespace
metadata:
  name: cnpg-system
  labels:
    db-access: "allow"
EOFNS

  cat > "${MANIFEST_DIR}/cluster.yaml" <<EOFCLUSTER
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: app-postgres
  namespace: databases
spec:
  instances: ${PG_INSTANCES[$K8S_CLUSTER]}
  imageName: ghcr.io/cloudnative-pg/postgresql:16.10-minimal-trixie
  storage:
    size: ${PG_STORAGE_SIZE[$K8S_CLUSTER]}
    storageClass: ${STORAGE_CLASS[$K8S_CLUSTER]}
    resizeInUseVolumes: true
  bootstrap:
    initdb:
      database: app
      owner: app
  enableSuperuserAccess: false
  enablePDB: true
  resources:
    requests:
      cpu: "${PG_CPU_REQUEST[$K8S_CLUSTER]}"
      memory: "${PG_MEMORY_REQUEST[$K8S_CLUSTER]}"
    limits:
      cpu: "${PG_CPU_LIMIT[$K8S_CLUSTER]}"
      memory: "${PG_MEMORY_LIMIT[$K8S_CLUSTER]}"
EOFCLUSTER

  cat > "${MANIFEST_DIR}/networkpolicy.yaml" <<'EOFNP'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-labeled-namespaces
  namespace: databases
spec:
  podSelector:
    matchLabels:
      cnpg.io/cluster: app-postgres
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              db-access: "allow"
      ports:
        - protocol: TCP
          port: 5432
        - protocol: TCP
          port: 8000
EOFNP

  cat > "${MANIFEST_DIR}/kustomization.yaml" <<'EOFK'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespaces.yaml
  - cluster.yaml
  - networkpolicy.yaml
EOFK

  log "manifests rendered to ${MANIFEST_DIR}"
}

# === OPERATOR MANAGEMENT ===
apply_operator() {
  local operator_manifest="${ARCHIVE_DIR}/cnpg-1.28.1.yaml"
  [[ -f "${operator_manifest}" ]] || fatal "operator manifest missing: ${operator_manifest}"
  
  log "applying CNPG operator (server-side apply)"
  if kubectl apply --server-side --force-conflicts -f "${operator_manifest}" >/dev/null 2>&1; then
    return 0
  fi
  log "server-side apply failed, retrying with normal apply"
  kubectl apply -f "${operator_manifest}" || fatal "operator apply failed"
}

wait_deployment() {
  local ns="$1" name="$2" timeout="$3"
  log "waiting for deployment ${name} in ${ns} (timeout ${timeout}s)"
  if ! kubectl -n "${ns}" rollout status deployment/"${name}" --timeout="${timeout}s" >/dev/null 2>&1; then
    log "deployment ${name} not ready; dumping pods"
    kubectl -n "${ns}" get pods -o wide || true
    fatal "deployment ${name} in ${ns} failed to become ready"
  fi
}

# === DIAGNOSTICS ===
dump_diagnostics() {
  log "=== OPERATOR: pods ==="
  kubectl -n cnpg-system get pods -o wide || true
  log "=== OPERATOR: logs (tail 300) ==="
  kubectl -n cnpg-system logs deployment/cnpg-controller-manager --tail=300 || true
  log "=== CLUSTER CR YAML ==="
  kubectl -n databases get cluster app-postgres -o yaml || true
  log "=== NAMESPACE PODS ==="
  kubectl -n databases get pods -o wide || true
  log "=== NAMESPACE EVENTS ==="
  kubectl -n databases get events --sort-by=.lastTimestamp || true
  log "=== PVC STATUS ==="
  kubectl -n databases get pvc -o wide || true
}

# === ROLLOUT ===
rollout() {
  require_bin kubectl
  
  render_manifests
  apply_operator
  
  if ! kubectl get namespace cnpg-system >/dev/null 2>&1; then
    kubectl create namespace cnpg-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  fi
  
  wait_deployment "cnpg-system" "cnpg-controller-manager" "${OPERATOR_TIMEOUT[$K8S_CLUSTER]}"
  
  log "applying cluster manifests via kustomize"
  if ! kubectl apply -k "${MANIFEST_DIR}" >/dev/null 2>&1; then
    log "kustomize apply failed; showing verbose output"
    kubectl apply -k "${MANIFEST_DIR}" -v=6 || true
  fi
  
  log "waiting for Cluster CR Ready (timeout ${CLUSTER_WAIT_TIMEOUT[$K8S_CLUSTER]}s)"
  if ! kubectl -n databases wait --for=condition=Ready "cluster/app-postgres" --timeout="${CLUSTER_WAIT_TIMEOUT[$K8S_CLUSTER]}s" >/dev/null 2>&1; then
    log "Cluster did not become Ready within ${CLUSTER_WAIT_TIMEOUT[$K8S_CLUSTER]}s"
    dump_diagnostics
    fatal "cluster app-postgres not Ready"
  fi
  
  local svc host port
  svc=$(kubectl -n databases get svc -l cnpg.io/cluster=app-postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -z "${svc}" ]] && svc="app-postgres"
  host="${svc}.databases.svc.cluster.local"
  port="5432"
  
  cat <<EOFCONNECTION

[SUCCESS] Rollout complete for K8S_CLUSTER=$K8S_CLUSTER

CONNECTION DETAILS:
  HOST=${host}
  PORT=${port}
  DATABASE=app
  APP_USER=app
  SUPERUSER_SECRET=app-postgres-superuser

APP connection string:
  postgresql://app:<PASSWORD>@${host}:${port}/app

NEXT STEPS:
  1. Retrieve password: kubectl -n databases get secret app-postgres-app -o jsonpath='{.data.password}' | base64 -d
  2. Test connection: kubectl -n databases run pg-test --rm -i --tty --image postgres:16 -- psql "postgresql://app:<PASSWORD>@${host}:${port}/app"
EOFCONNECTION
}

# === CLI INTERFACE ===
case "${1:-}" in
  --rollout)
    log "starting rollout for K8S_CLUSTER=$K8S_CLUSTER"
    rollout
    ;;
  --render-only)
    log "rendering manifests only (dry-run) for K8S_CLUSTER=$K8S_CLUSTER"
    render_manifests
    log "manifests written to ${MANIFEST_DIR}"
    echo "[DRY-RUN] To apply, run: $0 --rollout"
    ;;
  --diagnose)
    log "running diagnostics for K8S_CLUSTER=$K8S_CLUSTER"
    dump_diagnostics
    ;;
  --help|-h)
    cat <<EOFHELP
Usage: $0 [OPTION]

Environment variables:
  K8S_CLUSTER  Cluster type: 'kind' or 'eks' (default: kind)

Options:
  --rollout      Apply operator and Postgres cluster
  --render-only  Render manifests to disk without applying
  --diagnose     Dump diagnostic information
  --help, -h     Show this help message

Examples:
  K8S_CLUSTER=kind bash $0 --rollout
  K8S_CLUSTER=eks bash $0 --rollout
EOFHELP
    ;;
  *)
    echo "Unknown option: ${1:-}" >&2
    exit 1
    ;;
esac