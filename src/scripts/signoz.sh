#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly K8S_CLUSTER="${K8S_CLUSTER:-kind}"
readonly HELM_RELEASE="signoz"
readonly HELM_REPO="signoz"
readonly HELM_REPO_URL="https://charts.signoz.io"
readonly HELM_CHART="signoz/signoz"
readonly HELM_VERSION="0.113.0"
readonly NAMESPACE="signoz"

declare -A TIMEOUTS=(["kind"]="600" ["eks"]="900")
declare -A VALUES_FILES=(["kind"]="src/manifests/signoz/signoz_values_kind.yaml" ["eks"]="src/manifests/signoz/signoz_values_eks.yaml")

log() {
  printf '[%s] [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$K8S_CLUSTER" "$*" >&2
}

fatal() {
  printf '[ERROR] [%s] %s\n' "$K8S_CLUSTER" "$*" >&2
  exit 1
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"
}

dump_diagnostics() {
  log "=== SIGNOZ DIAGNOSTICS ==="
  kubectl -n "${NAMESPACE}" get pods -o wide 2>/dev/null || true
  kubectl -n "${NAMESPACE}" logs -l app.kubernetes.io/component=signoz-telemetrystore-migrator -c ready --tail=30 2>/dev/null || echo "No migrator logs"
  kubectl -n "${NAMESPACE}" exec -c clickhouse chi-signoz-clickhouse-cluster-0-0-0 -- clickhouse-client --query="SELECT 1" 2>/dev/null || echo "ClickHouse not ready"
  kubectl -n "${NAMESPACE}" get events --sort-by=.lastTimestamp 2>/dev/null | tail -10 || true
}

install_signoz() {
  require_bin helm kubectl
  readonly VALUES_FILE="${VALUES_FILES[$K8S_CLUSTER]}"
  [[ -f "${VALUES_FILE}" ]] || fatal "Values file not found: ${VALUES_FILE}"
  
  helm repo add "${HELM_REPO}" "${HELM_REPO_URL}" --force-update >/dev/null 2>&1
  helm repo update >/dev/null 2>&1
  
  if ! helm upgrade --install "${HELM_RELEASE}" "${HELM_CHART}" \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    --version "${HELM_VERSION}" \
    -f "${VALUES_FILE}" \
    --atomic \
    --timeout "${TIMEOUTS[$K8S_CLUSTER]}s" >/dev/null 2>&1; then
    log "Helm install failed. Gathering diagnostics..."
    dump_diagnostics
    fatal "Helm install failed after diagnostics"
  fi
  
  kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod -l component=query-service --timeout="${TIMEOUTS[$K8S_CLUSTER]}s" >/dev/null 2>&1 || {
    dump_diagnostics
    fatal "query-service not Ready"
  }
}

rollout() {
  log "starting rollout for K8S_CLUSTER=$K8S_CLUSTER"
  install_signoz
  cat <<EOF
[SUCCESS] Rollout complete for K8S_CLUSTER=$K8S_CLUSTER
NAMESPACE=${NAMESPACE}  RELEASE=${HELM_RELEASE}
UI: kubectl -n ${NAMESPACE} port-forward svc/signoz-frontend 3301:3301
EOF
}

cleanup() {
  require_bin helm kubectl
  helm uninstall "${HELM_RELEASE}" -n "${NAMESPACE}" --timeout=60s 2>/dev/null || true
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found --timeout=60s 2>/dev/null || true
  for i in {1..20}; do
    kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || { log "namespace deleted"; break; }
    sleep 3
  done
  log "cleanup complete"
}

case "${1:-}" in
  --rollout) rollout ;;
  --cleanup) cleanup ;;
  --diagnose) dump_diagnostics ;;
  *) fatal "Usage: $0 [--rollout|--cleanup|--diagnose]" ;;
esac