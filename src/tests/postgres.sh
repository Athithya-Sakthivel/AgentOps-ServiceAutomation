#!/usr/bin/env bash
set -euo pipefail

readonly NAMESPACE="${PG_NAMESPACE:-databases}"
readonly CLUSTER_NAME="${PG_CLUSTER_NAME:-app-postgres}"
readonly APP_SECRET="${PG_APP_SECRET:-app-postgres-app}"
readonly APP_USER="${PG_APP_USER:-app}"
readonly APP_DB="${PG_APP_DB:-app}"
readonly READ_SVC="${PG_READ_SVC:-app-postgres-r}"
readonly TIMEOUT="${PG_TEST_TIMEOUT:-30}"
readonly KUBECTL="${KUBECTL:-kubectl}"

log() { printf '[%s] [PG-TEST] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
info() { log "INFO: $*"; }
warn() { log "WARN: $*" >&2; }
fatal() { log "FATAL: $*" >&2; exit 1; }
require_bin() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"; }

gather_diagnostics() {
  local reason="${1:-unknown}"
  log "Gathering diagnostics for failure: ${reason}"
  {
    echo "=== POD STATUS ==="
    "${KUBECTL}" -n "${NAMESPACE}" get pods -l cnpg.io/cluster="${CLUSTER_NAME}" -o wide || true
    echo -e "\n=== POD LOGS (last 20 lines) ==="
    "${KUBECTL}" -n "${NAMESPACE}" logs -l cnpg.io/cluster="${CLUSTER_NAME}" -c postgres --tail=20 || true
    echo -e "\n=== SERVICE & ENDPOINTS ==="
    "${KUBECTL}" -n "${NAMESPACE}" get svc,ep -l cnpg.io/cluster="${CLUSTER_NAME}" || true
    echo -e "\n=== PVC STATUS ==="
    "${KUBECTL}" -n "${NAMESPACE}" get pvc -l cnpg.io/cluster="${CLUSTER_NAME}" -o wide || true
    echo -e "\n=== CLUSTER CR STATUS ==="
    "${KUBECTL}" -n "${NAMESPACE}" get cluster "${CLUSTER_NAME}" -o jsonpath='{.status.phase}{.status.conditions[*].type}' || true
    echo -e "\n=== RECENT EVENTS ==="
    "${KUBECTL}" -n "${NAMESPACE}" get events --sort-by=.lastTimestamp | tail -10 || true
    echo -e "\n=== SECRET EXISTS ==="
    "${KUBECTL}" -n "${NAMESPACE}" get secret "${APP_SECRET}" -o name 2>/dev/null || echo "SECRET_NOT_FOUND"
  } 2>&1 | sed 's/^/[DIAG] /'
}

test_prerequisites() {
  info "Checking prerequisites..."
  require_bin "${KUBECTL}"
  if ! "${KUBECTL}" get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    fatal "Namespace '${NAMESPACE}' not found"
  fi
  if ! "${KUBECTL}" -n "${NAMESPACE}" get secret "${APP_SECRET}" >/dev/null 2>&1; then
    fatal "Secret '${APP_SECRET}' not found in namespace '${NAMESPACE}'"
  fi
  if ! "${KUBECTL}" -n "${NAMESPACE}" wait --for=condition=Ready "pod/${CLUSTER_NAME}-1" --timeout="${TIMEOUT}s" >/dev/null 2>&1; then
    gather_diagnostics "pod_not_ready"
    fatal "Pod ${CLUSTER_NAME}-1 not Ready within ${TIMEOUT}s"
  fi
  info "Prerequisites passed"
}

test_connectivity() {
  info "Testing database connectivity..."
  local password
  password=$("${KUBECTL}" -n "${NAMESPACE}" get secret "${APP_SECRET}" -o jsonpath='{.data.password}' | base64 -d)
  [[ -z "${password}" ]] && fatal "Failed to extract password from secret"

  local result
  result=$("${KUBECTL}" -n "${NAMESPACE}" exec "${CLUSTER_NAME}-1" -c postgres -- \
    env "PGPASSWORD=${password}" psql -h localhost -U "${APP_USER}" -d "${APP_DB}" -c "SELECT 1 AS ok, current_timestamp AS ts;" \
    2>&1) || {
    gather_diagnostics "connectivity_failed"
    fatal "Connection test failed: ${result}"
  }

  if ! echo "${result}" | grep -q "(1 row)"; then
    gather_diagnostics "query_failed"
    fatal "Query did not return expected result: ${result}"
  fi
  info "Connectivity test passed"
}

test_schema() {
  info "Testing basic schema access..."
  local password
  password=$("${KUBECTL}" -n "${NAMESPACE}" get secret "${APP_SECRET}" -o jsonpath='{.data.password}' | base64 -d)
  
  local result
  result=$("${KUBECTL}" -n "${NAMESPACE}" exec "${CLUSTER_NAME}-1" -c postgres -- \
    env "PGPASSWORD=${password}" psql -h localhost -U "${APP_USER}" -d "${APP_DB}" -c "\dt" \
    2>&1) || {
    gather_diagnostics "schema_test_failed"
    fatal "Schema test failed: ${result}"
  }
  info "Schema test passed"
}

print_summary() {
  local password
  password=$("${KUBECTL}" -n "${NAMESPACE}" get secret "${APP_SECRET}" -o jsonpath='{.data.password}' | base64 -d)
  local host="${READ_SVC}.${NAMESPACE}.svc.cluster.local"
  cat <<EOFSUMMARY

[SUCCESS] Postgres subsystem tests passed

CONNECTION DETAILS (for downstream services):
  HOST=${host}
  PORT=5432
  DATABASE=${APP_DB}
  USER=${APP_USER}
  PASSWORD=${password}

CONNECTION STRINGS:
  URI:      postgresql://${APP_USER}:${password}@${host}:5432/${APP_DB}
  JDBC:     jdbc:postgresql://${host}:5432/${APP_DB}?user=${APP_USER}&password=${password}

USAGE EXAMPLES:
  # From within cluster (same namespace):
  kubectl -n ${NAMESPACE} exec -it ${CLUSTER_NAME}-1 -c postgres -- \\
    env PGPASSWORD="${password}" psql -h localhost -U ${APP_USER} -d ${APP_DB}
  
  # From ephemeral pod (external to DB pod):
  kubectl -n ${NAMESPACE} run pg-client --rm -i --tty --image postgres:16-alpine \\
    --env "PGPASSWORD=${password}" -- psql -h ${host} -U ${APP_USER} -d ${APP_DB}

HEALTH CHECK (for CI/CD or monitoring):
  kubectl -n ${NAMESPACE} exec ${CLUSTER_NAME}-1 -c postgres -- \\
    env PGPASSWORD="${password}" psql -h localhost -U ${APP_USER} -d ${APP_DB} -c "SELECT 1;" >/dev/null 2>&1

SECURITY NOTES:
  - Password shown above is for local/dev use only
  - Rotate credentials before production: kubectl cnpg reload ${CLUSTER_NAME} -n ${NAMESPACE}
  - Never commit secrets to version control

EOFSUMMARY
}

main() {
  log "Starting Postgres subsystem tests (namespace=${NAMESPACE}, cluster=${CLUSTER_NAME})"
  test_prerequisites
  test_connectivity
  test_schema
  print_summary
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
  PG_NAMESPACE         Postgres namespace (default: databases)
  PG_CLUSTER_NAME      CNPG cluster name (default: app-postgres)
  PG_APP_SECRET        App user secret name (default: app-postgres-app)
  PG_APP_USER          App database user (default: app)
  PG_APP_DB            App database name (default: app)
  PG_READ_SVC          Read service name (default: app-postgres-r)
  PG_TEST_TIMEOUT      Pod ready timeout seconds (default: 30)
  KUBECTL              kubectl binary path (default: kubectl)

Options:
  --test      Run full test suite (default)
  --diagnose  Gather diagnostics without running tests
  --help, -h  Show this help

Examples:
  bash $0 --test
  PG_CLUSTER_NAME=prod-pg bash $0 --test
  bash $0 --diagnose
EOFHELP
    ;;
  *) main ;;
esac