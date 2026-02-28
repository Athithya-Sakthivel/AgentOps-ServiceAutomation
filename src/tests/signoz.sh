#!/usr/bin/env bash
set -euo pipefail

readonly NAMESPACE="${SIGNOZ_NAMESPACE:-signoz}"
readonly HELM_RELEASE="${SIGNOZ_HELM_RELEASE:-signoz}"
readonly TIMEOUT="${SIGNOZ_TEST_TIMEOUT:-180}"
readonly KUBECTL="${KUBECTL:-kubectl}"

log() {
  printf '[%s] [SIGNOZ-TEST] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

fatal() {
  log "FATAL: $*" >&2
  exit 1
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"
}

gather_diagnostics() {
  log "DIAGNOSTICS: $1"
  "${KUBECTL}" -n "${NAMESPACE}" get pods -o wide || true
  "${KUBECTL}" -n "${NAMESPACE}" logs -l app.kubernetes.io/component=signoz-telemetrystore-migrator -c ready --tail=30 2>/dev/null || true
}

test_prerequisites() {
  require_bin "${KUBECTL}" helm
  "${KUBECTL}" get namespace "${NAMESPACE}" >/dev/null 2>&1 || fatal "Namespace '${NAMESPACE}' not found"
  helm status "${HELM_RELEASE}" -n "${NAMESPACE}" >/dev/null 2>&1 || fatal "Helm release '${HELM_RELEASE}' not found"
}

test_pods_ready() {
  for selector in "component=query-service" "app=clickhouse"; do
    "${KUBECTL}" -n "${NAMESPACE}" wait --for=condition=Ready pod -l "${selector}" --timeout="${TIMEOUT}s" >/dev/null 2>&1 || {
      gather_diagnostics "pods_not_ready_${selector}"
      fatal "Pods '${selector}' not Ready"
    }
  done
}

test_services() {
  for svc in signoz-frontend signoz-query-service signoz-otel-collector; do
    "${KUBECTL}" -n "${NAMESPACE}" get svc "${svc}" >/dev/null 2>&1 || {
      gather_diagnostics "missing_svc_${svc}"
      fatal "Service '${svc}' not found"
    }
  done
}

test_clickhouse() {
  local pod
  pod=$("${KUBECTL}" -n "${NAMESPACE}" get pods -l app=clickhouse -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [[ -n "${pod}" ]] || {
    gather_diagnostics "no_clickhouse_pod"
    fatal "ClickHouse pod not found"
  }
  "${KUBECTL}" -n "${NAMESPACE}" exec "${pod}" -c clickhouse -- clickhouse-client --query="SELECT 1" >/dev/null 2>&1 || {
    gather_diagnostics "clickhouse_query_failed"
    fatal "ClickHouse connectivity failed"
  }
}

test_metrics_endpoint() {
  local pf_pid
  "${KUBECTL}" -n "${NAMESPACE}" port-forward svc/signoz-query-service 8080:8080 >/dev/null 2>&1 &
  pf_pid=$!
  sleep 3
  curl -sf http://localhost:8080/metrics >/dev/null 2>&1 || {
    kill "${pf_pid}" 2>/dev/null || true
    wait "${pf_pid}" 2>/dev/null || true
    gather_diagnostics "metrics_unreachable"
    fatal "Metrics endpoint unreachable"
  }
  kill "${pf_pid}" 2>/dev/null || true
  wait "${pf_pid}" 2>/dev/null || true
}

main() {
  log "Starting tests (namespace=${NAMESPACE}, release=${HELM_RELEASE})"
  test_prerequisites
  test_pods_ready
  test_services
  test_clickhouse
  test_metrics_endpoint
  log "All tests passed"
  "${KUBECTL}" -n "${NAMESPACE}" get pods -o wide
}

case "${1:-}" in
  --test) main ;;
  --diagnose) gather_diagnostics "manual" ;;
  *) fatal "Usage: $0 [--test|--diagnose]" ;;
esac