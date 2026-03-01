#!/usr/bin/env bash
set -euo pipefail

readonly NAMESPACE="${SIGNOZ_NAMESPACE:-signoz}"
readonly TIMEOUT="${SIGNOZ_TEST_TIMEOUT:-180}"
readonly KUBECTL="${KUBECTL:-kubectl}"
readonly CLICKHOUSE_SERVICE="signoz-clickhouse"
readonly CLICKHOUSE_LABEL="clickhouse.altinity.com/chi=signoz-clickhouse"

log() { printf '[%s] [SIGNOZ-TEST] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
fatal() { log "FATAL: $*"; exit 1; }
require_bin() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"; }

gather_diagnostics() {
  log "DIAGNOSTICS: $1"
  "${KUBECTL}" -n "${NAMESPACE}" get pods -o wide || true
  "${KUBECTL}" -n "${NAMESPACE}" get svc -o wide || true
  "${KUBECTL}" -n "${NAMESPACE}" get endpoints || true
  "${KUBECTL}" -n "${NAMESPACE}" logs -l app.kubernetes.io/name=signoz --tail=50 2>/dev/null || true
  "${KUBECTL}" -n "${NAMESPACE}" logs -l "${CLICKHOUSE_LABEL}" --tail=50 2>/dev/null || true
  "${KUBECTL}" get events --sort-by=.lastTimestamp -n "${NAMESPACE}" 2>/dev/null | tail -20 || true
}

test_prerequisites() {
  require_bin "${KUBECTL}" helm
  "${KUBECTL}" get namespace "${NAMESPACE}" >/dev/null 2>&1 || fatal "Namespace '${NAMESPACE}' not found"
  helm status signoz -n "${NAMESPACE}" >/dev/null 2>&1 || fatal "Helm release 'signoz' not found"
  log "Prerequisites validated"
}

test_pods_ready() {
  log "Checking pod readiness"
  "${KUBECTL}" -n "${NAMESPACE}" wait --for=condition=Ready pod -l app.kubernetes.io/component=signoz --timeout="${TIMEOUT}s" >/dev/null 2>&1 || {
    gather_diagnostics "signoz_pod_not_ready"
    fatal "SigNoz pod not Ready"
  }
  "${KUBECTL}" -n "${NAMESPACE}" wait --for=condition=Ready pod -l app.kubernetes.io/component=otel-collector --timeout="${TIMEOUT}s" >/dev/null 2>&1 || {
    gather_diagnostics "otel_collector_not_ready"
    fatal "OTel Collector not Ready"
  }
  "${KUBECTL}" -n "${NAMESPACE}" wait --for=condition=Ready pod -l "${CLICKHOUSE_LABEL}" --timeout="${TIMEOUT}s" >/dev/null 2>&1 || {
    gather_diagnostics "clickhouse_not_ready"
    fatal "ClickHouse not Ready"
  }
  log "All pods ready"
}

test_services() {
  log "Checking services"
  for svc in signoz signoz-otel-collector "${CLICKHOUSE_SERVICE}" signoz-zookeeper; do
    "${KUBECTL}" -n "${NAMESPACE}" get svc "${svc}" >/dev/null 2>&1 || {
      gather_diagnostics "missing_svc_${svc}"
      fatal "Service '${svc}' not found"
    }
  done
  log "All services exist"
}

test_service_endpoints() {
  log "Checking service endpoints"
  for svc in "${CLICKHOUSE_SERVICE}" signoz-otel-collector signoz; do
    local endpoints
    endpoints=$("${KUBECTL}" -n "${NAMESPACE}" get endpoints "${svc}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null) || true
    [[ -n "${endpoints}" ]] || {
      gather_diagnostics "no_endpoints_${svc}"
      fatal "Service '${svc}' has no endpoints"
    }
    log "Service ${svc} has endpoints: ${endpoints}"
  done
}

test_clickhouse() {
  log "Testing ClickHouse connectivity"
  local pod
  pod=$("${KUBECTL}" -n "${NAMESPACE}" get pods -l "${CLICKHOUSE_LABEL}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [[ -n "${pod}" ]] || { gather_diagnostics "no_clickhouse_pod"; fatal "ClickHouse pod not found"; }
  
  log "Testing ClickHouse basic query"
  "${KUBECTL}" -n "${NAMESPACE}" exec "${pod}" -c clickhouse -- clickhouse-client --query="SELECT 1" >/dev/null 2>&1 || {
    gather_diagnostics "clickhouse_query_failed"
    fatal "ClickHouse basic query failed"
  }
  
  log "Testing ClickHouse cluster status"
  "${KUBECTL}" -n "${NAMESPACE}" exec "${pod}" -c clickhouse -- clickhouse-client --query="SELECT 1 FROM system.clusters WHERE cluster='cluster'" >/dev/null 2>&1 || {
    gather_diagnostics "clickhouse_cluster_failed"
    fatal "ClickHouse cluster query failed"
  }
  
  log "Testing ClickHouse migration status"
  "${KUBECTL}" -n "${NAMESPACE}" exec "${pod}" -c clickhouse -- clickhouse-client --query="SELECT migration_id FROM signoz_metrics.distributed_schema_migrations_v2 WHERE status='finished' ORDER BY migration_id DESC LIMIT 1" >/dev/null 2>&1 || {
    gather_diagnostics "clickhouse_migration_failed"
    fatal "ClickHouse migration query failed"
  }
  log "ClickHouse connectivity validated"
}

test_dns_resolution() {
  log "Testing DNS resolution for ClickHouse service"
  local pod
  pod=$("${KUBECTL}" -n "${NAMESPACE}" get pods -l app.kubernetes.io/component=signoz -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [[ -n "${pod}" ]] || { gather_diagnostics "no_signoz_pod_for_dns"; fatal "SigNoz pod not found for DNS test"; }
  
  "${KUBECTL}" -n "${NAMESPACE}" exec "${pod}" -- nslookup "${CLICKHOUSE_SERVICE}.${NAMESPACE}.svc.cluster.local" >/dev/null 2>&1 || {
    gather_diagnostics "dns_resolution_failed"
    fatal "DNS resolution for ClickHouse service failed"
  }
  log "DNS resolution successful"
}

test_metrics_endpoint() {
  log "Testing metrics endpoint"
  local pf_pid
  "${KUBECTL}" -n "${NAMESPACE}" port-forward svc/signoz 8080:8080 >/dev/null 2>&1 &
  pf_pid=$!
  trap "kill ${pf_pid} 2>/dev/null || true; wait ${pf_pid} 2>/dev/null || true" EXIT
  sleep 3
  curl -sf http://localhost:8080/metrics >/dev/null 2>&1 || {
    gather_diagnostics "metrics_unreachable"
    fatal "Metrics endpoint unreachable"
  }
  kill "${pf_pid}" 2>/dev/null || true
  wait "${pf_pid}" 2>/dev/null || true
  trap - EXIT
  log "Metrics endpoint accessible"
}

test_secrets() {
  log "Checking required secrets"
  "${KUBECTL}" -n "${NAMESPACE}" get secret signoz-secrets >/dev/null 2>&1 || {
    gather_diagnostics "missing_secrets"
    fatal "Secret 'signoz-secrets' not found"
  }
  
  local required_keys=("jwt-secret" "clickhouse-user" "clickhouse-password" "clickhouse-host" "clickhouse-port")
  for key in "${required_keys[@]}"; do
    "${KUBECTL}" -n "${NAMESPACE}" get secret signoz-secrets -o jsonpath="{.data.${key}}" >/dev/null 2>&1 || {
      gather_diagnostics "missing_secret_key_${key}"
      fatal "Secret key '${key}' not found in signoz-secrets"
    }
  done
  log "All required secrets present"
}

main() {
  log "Starting SigNoz tests (namespace=${NAMESPACE})"
  test_prerequisites
  test_secrets
  test_pods_ready
  test_services
  test_service_endpoints
  test_dns_resolution
  test_clickhouse
  test_metrics_endpoint
  log "All tests passed"
  "${KUBECTL}" -n "${NAMESPACE}" get pods -o wide
}

main