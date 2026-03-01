#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly K8S_CLUSTER="${K8S_CLUSTER:-kind}"
readonly HELM_RELEASE="kuberay-operator"
readonly HELM_REPO="kuberay"
readonly HELM_REPO_URL="https://ray-project.github.io/kuberay-helm/"
readonly HELM_CHART="kuberay/kuberay-operator"
readonly HELM_VERSION="1.5.1"
readonly NAMESPACE="ray-system"

declare -A REPLICAS=( ["kind"]="1" ["eks"]="2" )
declare -A TIMEOUTS=( ["kind"]="120" ["eks"]="300" )

log() { printf '[%s] [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$K8S_CLUSTER" "$*" >&2; }
fatal() { printf '[ERROR] [%s] %s\n' "$K8S_CLUSTER" "$*" >&2; exit 1; }
require_bin() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"; }

install_operator() {
  require_bin helm
  require_bin kubectl
  
  log "adding Helm repo ${HELM_REPO}"
  helm repo add "${HELM_REPO}" "${HELM_REPO_URL}" --force-update >/dev/null 2>&1
  helm repo update >/dev/null 2>&1
  
  log "installing KubeRay operator (chart version ${HELM_VERSION})"
  helm upgrade --install "${HELM_RELEASE}" "${HELM_CHART}" \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    --version "${HELM_VERSION}" \
    --set "replicaCount=${REPLICAS[$K8S_CLUSTER]}" \
    --wait --atomic \
    --timeout "${TIMEOUTS[$K8S_CLUSTER]}s" >/dev/null 2>&1 || fatal "Helm install/upgrade failed"
  
  log "verifying CRDs are installed"
  for crd in rayclusters.ray.io rayservices.ray.io rayjobs.ray.io; do
    if ! kubectl get crd "${crd}" >/dev/null 2>&1; then
      fatal "CRD ${crd} not found after operator install"
    fi
  done
  
  log "waiting for operator deployment ready"
  kubectl -n "${NAMESPACE}" rollout status deployment/"${HELM_RELEASE}" --timeout="${TIMEOUTS[$K8S_CLUSTER]}s" >/dev/null 2>&1 || \
    fatal "Operator deployment not ready"
}

dump_diagnostics() {
  log "=== OPERATOR: pods ==="
  kubectl -n "${NAMESPACE}" get pods -o wide || true
  log "=== OPERATOR: logs (tail 300) ==="
  kubectl -n "${NAMESPACE}" logs deployment/"${HELM_RELEASE}" --tail=300 || true
  log "=== OPERATOR: events ==="
  kubectl -n "${NAMESPACE}" get events --sort-by=.lastTimestamp || true
  log "=== CRD STATUS ==="
  kubectl get crds | grep ray || true
  log "=== HELM RELEASE ==="
  helm status "${HELM_RELEASE}" -n "${NAMESPACE}" 2>/dev/null || echo "HELM_RELEASE_NOT_FOUND"
}

rollout() {
  log "starting rollout for K8S_CLUSTER=$K8S_CLUSTER"
  install_operator
  
  cat <<EOFNEXT

[SUCCESS] Rollout complete for K8S_CLUSTER=$K8S_CLUSTER

OPERATOR DETAILS:
  NAMESPACE=${NAMESPACE}
  RELEASE=${HELM_RELEASE}
  REPLICAS=${REPLICAS[$K8S_CLUSTER]}

NEXT STEPS:
  1. Verify CRDs: kubectl get crds | grep ray
  2. Check operator: kubectl -n ${NAMESPACE} get pods
  3. Run tests: K8S_CLUSTER=${K8S_CLUSTER} bash ${SCRIPT_DIR}/../tests/kuberay_operator.sh --test
EOFNEXT
}

cleanup() {
  require_bin helm
  require_bin kubectl
  
  log "starting cleanup for K8S_CLUSTER=$K8S_CLUSTER"
  helm uninstall "${HELM_RELEASE}" -n "${NAMESPACE}" --timeout=60s || true
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found --timeout=60s || true
  
  cat <<EOFCLEANUP

[SUCCESS] Cleanup complete for K8S_CLUSTER=$K8S_CLUSTER
EOFCLEANUP
}

case "${1:-}" in
  --rollout) rollout ;;
  --cleanup) cleanup ;;
  --diagnose) dump_diagnostics ;;
  --help|-h)
    cat <<EOFHELP
Usage: $0 [OPTION]

Environment variables:
  K8S_CLUSTER  Cluster type: 'kind' or 'eks' (default: kind)

Options:
  --rollout    Install KubeRay operator
  --cleanup    Remove operator and namespace
  --diagnose   Dump diagnostic information
  --help, -h   Show this help

Examples:
  K8S_CLUSTER=kind bash $0 --rollout
  K8S_CLUSTER=eks bash $0 --rollout
EOFHELP
    ;;
  *) fatal "Unknown option: ${1:-}" ;;
esac