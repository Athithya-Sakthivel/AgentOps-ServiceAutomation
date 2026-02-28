#!/usr/bin/env bash
set -euo pipefail

readonly NAMESPACE="${RAY_NAMESPACE:-ray-system}"
readonly HELM_RELEASE="${RAY_HELM_RELEASE:-kuberay-operator}"
readonly TIMEOUT="${RAY_TEST_TIMEOUT:-60}"
readonly KUBECTL="${KUBECTL:-kubectl}"

log() { printf '[%s] [RAY-OP-TEST] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
info() { log "INFO: $*"; }
warn() { log "WARN: $*" >&2; }
fatal() { log "FATAL: $*" >&2; exit 1; }
require_bin() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"; }

gather_diagnostics() {
  local reason="${1:-unknown}"
  log "Gathering diagnostics for failure: ${reason}"
  {
    echo "=== POD STATUS ==="
    "${KUBECTL}" -n "${NAMESPACE}" get pods -o wide || true
    echo -e "\n=== POD LOGS ==="
    "${KUBECTL}" -n "${NAMESPACE}" logs deployment/"${HELM_RELEASE}" --tail=100 || true
    echo -e "\n=== EVENTS ==="
    "${KUBECTL}" -n "${NAMESPACE}" get events --sort-by=.lastTimestamp | tail -10 || true
    echo -e "\n=== CRD STATUS ==="
    kubectl get crds | grep ray || true
    echo -e "\n=== HELM STATUS ==="
    helm status "${HELM_RELEASE}" -n "${NAMESPACE}" 2>/dev/null || echo "HELM_RELEASE_NOT_FOUND"
  } 2>&1 | sed 's/^/[DIAG] /'
}

test_prerequisites() {
  info "Checking prerequisites..."
  require_bin "${KUBECTL}"
  require_bin helm
  
  if ! "${KUBECTL}" get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    fatal "Namespace '${NAMESPACE}' not found"
  fi
  if ! helm status "${HELM_RELEASE}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    fatal "Helm release '${HELM_RELEASE}' not found"
  fi
  info "Prerequisites passed"
}

test_crds() {
  info "Testing CRDs are installed..."
  for crd in rayclusters.ray.io rayservices.ray.io rayjobs.ray.io; do
    if ! "${KUBECTL}" get crd "${crd}" >/dev/null 2>&1; then
      gather_diagnostics "crd_missing_${crd}"
      fatal "CRD ${crd} not found"
    fi
  done
  info "CRDs test passed"
}

test_operator_ready() {
  info "Testing operator deployment ready..."
  if ! "${KUBECTL}" -n "${NAMESPACE}" wait --for=condition=Available "deployment/${HELM_RELEASE}" --timeout="${TIMEOUT}s" >/dev/null 2>&1; then
    gather_diagnostics "operator_not_ready"
    fatal "Operator deployment not Available within ${TIMEOUT}s"
  fi
  info "Operator ready test passed"
}

test_operator_pods() {
  info "Testing operator pods are running..."
  local ready_pods
  ready_pods=$("${KUBECTL}" -n "${NAMESPACE}" get pods -l "app.kubernetes.io/name=kuberay-operator" -o jsonpath='{.items[*].status.phase}' 2>/dev/null || true)
  
  if [[ -z "${ready_pods}" ]]; then
    gather_diagnostics "no_operator_pods"
    fatal "No operator pods found"
  fi
  
  if echo "${ready_pods}" | grep -qv "Running"; then
    gather_diagnostics "pods_not_running"
    fatal "Operator pods not in Running state: ${ready_pods}"
  fi
  info "Operator pods test passed"
}

print_summary() {
  cat <<EOFSUMMARY

[SUCCESS] KubeRay operator tests passed

OPERATOR DETAILS:
  NAMESPACE=${NAMESPACE}
  RELEASE=${HELM_RELEASE}

EOFSUMMARY
}

main() {
  log "Starting KubeRay operator tests (namespace=${NAMESPACE}, release=${HELM_RELEASE})"
  test_prerequisites
  test_crds
  test_operator_ready
  test_operator_pods
  print_summary
  kubectl get pods -A
  kubectl -n ${NAMESPACE} logs deployment/${HELM_RELEASE}
  kubectl get crds | grep ray && helm status ${HELM_RELEASE} -n ${NAMESPACE}
  kubectl -n ${NAMESPACE} wait --for=condition=Available deployment/${HELM_RELEASE} --timeout=60s
  log "All tests passed"
  exit 0
}

case "${1:-}" in
  --test) main ;;
  --diagnose)
    log "Running diagnostics only"
    gather_diagnostics "manual_request"
    ;;
  --help|-h)
    cat <<EOFHELP
Usage: $0 [OPTION]

Environment variables (all optional):
  RAY_NAMESPACE       Operator namespace (default: ray-system)
  RAY_HELM_RELEASE    Helm release name (default: kuberay-operator)
  RAY_TEST_TIMEOUT    Ready timeout seconds (default: 60)
  KUBECTL             kubectl binary path (default: kubectl)

Options:
  --test      Run full test suite (default)
  --diagnose  Gather diagnostics without running tests
  --help, -h  Show this help

Examples:
  bash $0 --test
  RAY_NAMESPACE=ray-system bash $0 --test
  bash $0 --diagnose
EOFHELP
    ;;
  *) main ;;
esac