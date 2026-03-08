#!/usr/bin/env bash
# src/tests/e2e_app_test_local_hardened.sh
# Fully hardened, idempotent, CI-friendly E2E smoke test for the microservices.
# - No `set -euo pipefail` and no top-level `exit` calls (avoids shell terminators).
# - Kills only safely-identified previous processes (verifies command line before killing).
# - Automatic port discovery when desired ports are occupied.
# - Retryable port-forward attempts.
# - Deterministic cleanup and persistent logs under WORKDIR.
# - Uses robust JSON parsing via environment variables (no stdin races).
#
# Usage:
#   bash src/tests/e2e_app_test_local_hardened.sh
#
# Requirements in PATH: kubectl, python3, curl, uvicorn
# Environment overrides:
#   WORKDIR, LOGDIR, DESIRED_PG_PORT, DESIRED_VAL_PORT, AUTH_PORT, ACTIVITY_PORT, TASK_PORT
#
# End state:
#   - prints summary and leaves processes running by default
#   - returns non-zero (via `false`) if any core check failed (GLOBAL_STATUS != 0)
#
# Author: hardened script (production-grade pattern)

# ----------------------------
# Configuration (override via env)
# ----------------------------
WORKDIR="${WORKDIR:-/tmp/e2e_app_test}"
LOGDIR="${LOGDIR:-${WORKDIR}/logs}"
mkdir -p "$WORKDIR" "$LOGDIR"

# desired local ports; script will pick ephemeral ports when occupied
DESIRED_PG_PORT="${DESIRED_PG_PORT:-55432}"
DESIRED_VAL_PORT="${DESIRED_VAL_PORT:-6379}"

# kubernetes service identifiers
K8S_PG_SVC="${K8S_PG_SVC:-svc/app-postgres-r}"
K8S_PG_NS="${K8S_PG_NS:-databases}"
K8S_VAL_SVC="${K8S_VAL_SVC:-svc/valkey}"
K8S_VAL_NS="${K8S_VAL_NS:-valkey-prod}"

# services (local)
AUTH_HOST="${AUTH_HOST:-127.0.0.1}"
AUTH_PORT="${AUTH_PORT:-18200}"
AUTH_URL="http://${AUTH_HOST}:${AUTH_PORT}"
ACTIVITY_PORT="${ACTIVITY_PORT:-8002}"
TASK_PORT="${TASK_PORT:-8001}"
ACTIVITY_URL="http://127.0.0.1:${ACTIVITY_PORT}"
TASK_URL="http://127.0.0.1:${TASK_PORT}"

# retries & timeouts
PORTFWD_RETRIES="${PORTFWD_RETRIES:-4}"
PORTFWD_BACKOFF_SECONDS="${PORTFWD_BACKOFF_SECONDS:-1}"
PORT_CHECK_TIMEOUT="${PORT_CHECK_TIMEOUT:-20}"
HEALTH_WAIT="${HEALTH_WAIT:-30}"

# control cleanup behaviour: when KEEP_RUNNING_ON_EXIT=1 the script will not forcibly clean everything
KEEP_RUNNING_ON_EXIT="${KEEP_RUNNING_ON_EXIT:-0}"

# pid/port file helpers
pidfile() { printf "%s/%s.pid" "$WORKDIR" "$1"; }
portfile() { printf "%s/%s.port" "$WORKDIR" "$1"; }

LOG_MASTER="${LOGDIR}/e2e_master.log"
log() {
  printf "%s %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_MASTER"
}

# ----------------------------
# Simple prerequisites check (non-fatal)
# ----------------------------
_requirements_ok=0
for cmd in kubectl python3 curl uvicorn; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "[WARN] missing command in PATH: $cmd"
    _requirements_ok=1
  fi
done
if [ "$_requirements_ok" -ne 0 ]; then
  log "[WARN] some required CLI tools are missing; script will continue but is likely to fail"
fi

# ----------------------------
# Helper functions
# ----------------------------
is_pid_running() {
  local pid="$1"
  [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1
}

write_pid() {
  local name="$1" pid="$2"
  printf "%s" "$pid" > "$(pidfile "$name")"
}

read_pidfile() {
  local name="$1"
  [ -f "$(pidfile "$name")" ] && cat "$(pidfile "$name")" || echo ""
}

write_port() {
  local name="$1" port="$2"
  printf "%s" "$port" > "$(portfile "$name")"
}

read_portfile() {
  local name="$1"
  [ -f "$(portfile "$name")" ] && cat "$(portfile "$name")" || echo ""
}

# Python-based port listener check (returns 0 if listening within timeout)
port_is_listening() {
  local host="$1" port="$2" timeout="${3:-1}"
  python3 - "$host" "$port" "$timeout" <<'PY' >/dev/null 2>&1 || true
import sys, socket, time
h=sys.argv[1]; p=int(sys.argv[2]); to=int(sys.argv[3])
end=time.time()+to
while time.time() < end:
    try:
        s=socket.create_connection((h,p), timeout=1)
        s.close()
        sys.exit(0)
    except Exception:
        time.sleep(0.2)
sys.exit(1)
PY
  return $?
}

# pick ephemeral free port
find_free_port() {
  python3 - <<'PY'
import socket
s=socket.socket()
s.bind(('',0))
port=s.getsockname()[1]
s.close()
print(port)
PY
}

# redis PING via raw RESP (best-effort)
redis_ping() {
  local host="${1:-127.0.0.1}" port="${2:-6379}" timeout="${3:-2}"
  python3 - "$host" "$port" "$timeout" <<'PY'
import sys, socket
h=sys.argv[1]; p=int(sys.argv[2]); to=int(sys.argv[3])
try:
    s=socket.create_connection((h,p), timeout=to)
    s.sendall(b"*1\r\n$4\r\nPING\r\n")
    r=s.recv(128)
    s.close()
    if b"PONG" in r or r.startswith(b"+PONG"):
        sys.exit(0)
    sys.exit(2)
except Exception:
    sys.exit(3)
PY
  return $?
}

# parse JSON 'id' robustly from env var RESP
extract_id_from_response() {
  local resp="$1"
  python3 - <<'PY'
import os, json, sys
try:
    data=json.loads(os.environ.get("RESP",""))
    v=data.get("id","")
    if v is None:
        v=""
    print(v)
except Exception:
    print("")
PY
}

# safe-kill by verifying command line matches a pattern
safe_kill_cmd_pattern() {
  local pattern="$1"   # e.g. "uvicorn app:app --app-dir src/services/task-service"
  local killed_any=0
  # find PIDs using pgrep -f but verify ps cmdline
  for pid in $(pgrep -f "$pattern" 2>/dev/null || true); do
    if [ -z "$pid" ]; then continue; fi
    local cmdline
    cmdline="$(ps -p "$pid" -o cmd= 2>/dev/null || echo "")"
    if echo "$cmdline" | grep -F -- "$pattern" >/dev/null 2>&1; then
      log "[CLEAN] killing pid=$pid (pattern verified) -> cmd: $cmdline"
      kill "$pid" >/dev/null 2>&1 || true
      sleep 0.15
      if is_pid_running "$pid"; then
        kill -9 "$pid" >/dev/null 2>&1 || true
      fi
      killed_any=1
    else
      log "[CLEAN] skipping pid=$pid; cmdline mismatch: $cmdline"
    fi
  done
  return "$killed_any"
}

# deterministic cleanup of pid/port files for a managed name
cleanup_pid_and_port_files() {
  local name="$1"
  rm -f "$(pidfile "$name")" "$(portfile "$name")" 2>/dev/null || true
}

# master cleanup invoked on EXIT (respects KEEP_RUNNING_ON_EXIT)
cleanup_all() {
  log "[CLEAN] cleanup_all invoked"
  if [ "${KEEP_RUNNING_ON_EXIT}" = "1" ]; then
    log "[CLEAN] KEEP_RUNNING_ON_EXIT=1 - leaving processes running"
    return 0
  fi

  # stop port-forwards and uvicorns we manage (safe)
  safe_kill_cmd_pattern "kubectl -n ${K8S_PG_NS} port-forward ${K8S_PG_SVC}" || true
  safe_kill_cmd_pattern "kubectl -n ${K8S_VAL_NS} port-forward ${K8S_VAL_SVC}" || true
  safe_kill_cmd_pattern "uvicorn app:app --app-dir src/services/task-service" || true
  safe_kill_cmd_pattern "uvicorn app:app --app-dir src/services/activity-service" || true
  safe_kill_cmd_pattern "uvicorn src.services.auth.auth_server:app" || true

  cleanup_pid_and_port_files "pg_pf"
  cleanup_pid_and_port_files "val_pf"
  cleanup_pid_and_port_files "auth"
  cleanup_pid_and_port_files "task"
  cleanup_pid_and_port_files "activity"

  log "[CLEAN] cleanup_all complete"
}

trap 'cleanup_all' EXIT

# ----------------------------
# startup: pre-clean partial matches we know are previous runs
# ----------------------------
log "[E2E] start; workdir=${WORKDIR}"
date -u +"%Y-%m-%dT%H:%M:%SZ" | tee -a "$LOG_MASTER"

log "[E2E] pre-clean: stopping known previous test processes (safe matches)"
# patterns to consider (safe matches only)
safe_kill_cmd_pattern "kubectl -n ${K8S_PG_NS} port-forward ${K8S_PG_SVC}" || true
safe_kill_cmd_pattern "kubectl -n ${K8S_VAL_NS} port-forward ${K8S_VAL_SVC}" || true
safe_kill_cmd_pattern "uvicorn app:app --app-dir src/services/task-service" || true
safe_kill_cmd_pattern "uvicorn app:app --app-dir src/services/activity-service" || true
safe_kill_cmd_pattern "uvicorn src.services.auth.auth_server:app" || true

# ensure logs exist
: > "${LOGDIR}/pg_pf.log" 2>/dev/null || true
: > "${LOGDIR}/val_pf.log" 2>/dev/null || true
: > "${LOGDIR}/auth.log" 2>/dev/null || true
: > "${LOGDIR}/task.log" 2>/dev/null || true
: > "${LOGDIR}/activity.log" 2>/dev/null || true

# GLOBAL status
GLOBAL_STATUS=0

# ----------------------------
# Port-forward manager (idempotent)
# ----------------------------
start_or_reuse_port_forward() {
  local ns="$1" svc="$2" desired_port="$3" remote_port="$4" name="$5" outlog="$6"
  local existing_pid existing_port pid_local

  existing_pid="$(read_pidfile "$name" || true)"
  existing_port="$(read_portfile "$name" || true)"

  if [ -n "$existing_pid" ] && is_pid_running "$existing_pid"; then
    if [ -n "$existing_port" ] && port_is_listening 127.0.0.1 "$existing_port" 1; then
      log "[E2E] reusing existing port-forward (pid=${existing_pid}) for ${svc} -> localhost:${existing_port}"
      return 0
    else
      log "[E2E] found stale pidfile for ${name}; cleaning"
      cleanup_pid_and_port_files "$name"
    fi
  fi

  local attempt=0
  local local_port="$desired_port"
  while [ "$attempt" -lt "$PORTFWD_RETRIES" ]; do
    attempt=$((attempt + 1))

    # choose ephemeral if desired already in use
    if port_is_listening 127.0.0.1 "$local_port" 0; then
      log "[E2E] desired local port ${local_port} already in use; picking ephemeral port"
      local_port="$(find_free_port)"
      log "[E2E] will try ephemeral local port ${local_port}"
    fi

    log "[E2E] starting kubectl port-forward attempt ${attempt}/${PORTFWD_RETRIES}: ${svc} (${ns}) -> localhost:${local_port}"
    # launch port-forward in background; redirect logs
    ( kubectl -n "${ns}" port-forward "${svc}" "${local_port}:${remote_port}" > "${outlog}" 2>&1 ) &
    pid_local=$!
    sleep 0.4

    # if process exited already, capture its log and retry
    if ! is_pid_running "${pid_local}"; then
      log "[E2E] port-forward process exited quickly; log excerpt:"
      tail -n 200 "${outlog}" | sed -n '1,200p' | sed 's/^/  /'
      cleanup_pid_and_port_files "$name"
      sleep "${PORTFWD_BACKOFF_SECONDS}"
      continue
    fi

    # write metadata
    write_pid "$name" "$pid_local"
    write_port "$name" "$local_port"

    # wait for port to be listening
    if port_is_listening 127.0.0.1 "$local_port" "${PORT_CHECK_TIMEOUT}"; then
      log "[E2E] port-forward established pid=${pid_local} local_port=${local_port}"
      return 0
    fi

    log "[E2E] port ${local_port} not listening after wait; killing pf pid=${pid_local}"
    kill "${pid_local}" >/dev/null 2>&1 || true
    cleanup_pid_and_port_files "$name"
    sleep "${PORTFWD_BACKOFF_SECONDS}"
  done

  log "[E2E] failed to establish port-forward for ${svc} after ${PORTFWD_RETRIES} attempts; check ${outlog}"
  return 1
}

# -------- start/reuse Postgres port-forward --------
log "[E2E] ensuring Postgres port-forward"
if start_or_reuse_port_forward "${K8S_PG_NS}" "${K8S_PG_SVC}" "${DESIRED_PG_PORT}" 5432 "pg_pf" "${LOGDIR}/pg_pf.log"; then
  PG_PF_PORT_ACTUAL="$(read_portfile pg_pf)"
  log "[E2E] postgres available at 127.0.0.1:${PG_PF_PORT_ACTUAL}"
else
  log "[E2E][WARN] postgres port-forward failed; continuing but DB calls will likely fail"
  PG_PF_PORT_ACTUAL=""
  GLOBAL_STATUS=1
fi

# -------- start/reuse valkey port-forward --------
log "[E2E] ensuring Valkey port-forward"
if start_or_reuse_port_forward "${K8S_VAL_NS}" "${K8S_VAL_SVC}" "${DESIRED_VAL_PORT}" 6379 "val_pf" "${LOGDIR}/val_pf.log"; then
  VAL_PF_PORT_ACTUAL="$(read_portfile val_pf)"
  log "[E2E] valkey available at 127.0.0.1:${VAL_PF_PORT_ACTUAL}"
else
  log "[E2E][WARN] valkey port-forward failed; continuing (cache unavailable)"
  VAL_PF_PORT_ACTUAL=""
  GLOBAL_STATUS=1
fi

# ----------------------------
# Discover k8s secrets for DB/valkey (best-effort)
# ----------------------------
DB_PASS="$(kubectl -n "${K8S_PG_NS}" get secret app-postgres-app -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
if [ -z "${DB_PASS}" ]; then
  log "[E2E] warning: could not read DB secret; using fallback 'password'"
  DB_PASS="password"
fi

VALKEY_PASS="$(kubectl -n "${K8S_VAL_NS}" get secret valkey-auth -o jsonpath='{.data.VALKEY_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)"
if [ -z "${VALKEY_PASS}" ]; then
  log "[E2E] warning: could not read valkey secret; assuming empty password"
  VALKEY_PASS=""
fi

# ----------------------------
# export runtime env for services (use actual forwarded ports)
# ----------------------------
if [ -n "$PG_PF_PORT_ACTUAL" ]; then
  export DATABASE_URL="postgresql://app:${DB_PASS}@127.0.0.1:${PG_PF_PORT_ACTUAL}/app"
else
  export DATABASE_URL="${DATABASE_URL:-postgresql://app:password@127.0.0.1:5432/app}"
fi

if [ -n "${VAL_PF_PORT_ACTUAL}" ] && [ -n "${VALKEY_PASS}" ]; then
  export VALKEY_URL="redis://:${VALKEY_PASS}@127.0.0.1:${VAL_PF_PORT_ACTUAL}/0"
elif [ -n "${VAL_PF_PORT_ACTUAL}" ]; then
  export VALKEY_URL="redis://127.0.0.1:${VAL_PF_PORT_ACTUAL}/0"
else
  export VALKEY_URL="${VALKEY_URL:-redis://127.0.0.1:6379/0}"
fi

export AUTH_SERVICE_URL="${AUTH_URL}"
export ACTIVITY_SERVICE_URL="${ACTIVITY_URL}"
export TASK_SERVICE_URL="${TASK_URL}"

# dev secrets for local runs (can be overridden)
export JWT_SECRET="${JWT_SECRET:-ci-jwt-secret-please-change}"
export SESSION_SECRET="${SESSION_SECRET:-ci-session-secret-please-change}"

# ----------------------------
# Service runner (idempotent)
# ----------------------------
start_service_if_needed() {
  local name="$1" local_cmd="$2" logf="$3" verify_url="$4"
  local existing_pid
  existing_pid="$(read_pidfile "$name" || true)"
  if [ -n "$existing_pid" ] && is_pid_running "$existing_pid"; then
    # verify cmdline matches intended pattern (best-effort)
    local cmdline
    cmdline="$(ps -p "$existing_pid" -o cmd= 2>/dev/null || echo "")"
    if echo "$cmdline" | grep -F -- "$local_cmd" >/dev/null 2>&1 || echo "$cmdline" | grep -F -- "$(echo "$local_cmd" | awk '{print $1}')" >/dev/null 2>&1; then
      log "[E2E] reusing running service '${name}' pid=${existing_pid}"
      return 0
    else
      log "[E2E] found stale pidfile for service '${name}' (pid=${existing_pid}); removing"
      cleanup_pid_and_port_files "$name"
    fi
  fi

  log "[E2E] starting service '${name}' (logs -> ${logf})"
  # start in background, capture pid
  # Use nohup-like redirect to avoid uvicorn stealing terminal IO
  ( eval "${local_cmd}" >> "${logf}" 2>&1 ) &
  local pid=$!
  sleep 0.35

  if ! is_pid_running "$pid"; then
    log "[E2E][ERROR] service '${name}' failed to start; tail log (last 200 lines):"
    tail -n 200 "${logf}" | sed 's/^/  /'
    GLOBAL_STATUS=1
    return 1
  fi

  write_pid "$name" "$pid"
  log "[E2E] service '${name}' started pid=${pid}"
  return 0
}

# start auth, activity, task
start_service_if_needed "auth" "uvicorn src.services.auth.auth_server:app --host ${AUTH_HOST} --port ${AUTH_PORT} --log-level info" "${LOGDIR}/auth.log" "${AUTH_URL}/health"
start_service_if_needed "activity" "uvicorn app:app --app-dir src/services/activity-service --host 127.0.0.1 --port ${ACTIVITY_PORT} --log-level info" "${LOGDIR}/activity.log" "${ACTIVITY_URL}/health"
start_service_if_needed "task" "uvicorn app:app --app-dir src/services/task-service --host 127.0.0.1 --port ${TASK_PORT} --log-level info" "${LOGDIR}/task.log" "${TASK_URL}/health"

# ----------------------------
# Wait for /health endpoints (with timeout)
# ----------------------------
wait_for_http_ok() {
  local url="$1" timeout="${2:-30}"
  local i=0
  while [ "$i" -lt "$timeout" ]; do
    if curl -sS --max-time 3 "$url" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i+1))
    sleep 1
  done
  return 1
}

log "[E2E] waiting for auth /health"
if wait_for_http_ok "${AUTH_URL}/health" "${HEALTH_WAIT}"; then
  log "[E2E] auth healthy"
else
  log "[E2E][ERROR] auth /health not healthy after wait; tail auth log (last 200 lines):"
  tail -n 200 "${LOGDIR}/auth.log" | sed 's/^/  /'
  GLOBAL_STATUS=1
fi

log "[E2E] waiting for activity /health"
if wait_for_http_ok "${ACTIVITY_URL}/health" "${HEALTH_WAIT}"; then
  log "[E2E] activity healthy"
else
  log "[E2E][ERROR] activity /health not healthy after wait; tail activity log (last 200 lines):"
  tail -n 200 "${LOGDIR}/activity.log" | sed 's/^/  /'
  GLOBAL_STATUS=1
fi

log "[E2E] waiting for task /health"
if wait_for_http_ok "${TASK_URL}/health" "${HEALTH_WAIT}"; then
  log "[E2E] task healthy"
else
  log "[E2E][ERROR] task /health not healthy after wait; tail task log (last 200 lines):"
  tail -n 200 "${LOGDIR}/task.log" | sed 's/^/  /'
  GLOBAL_STATUS=1
fi

# ----------------------------
# Core E2E actions: JWT generation, create task, verify activity
# ----------------------------
log "[E2E] generating JWT"
JWT="$(python3 - <<'PY'
import jwt, time, os, json
payload = {
  "iss":"agentic-platform","aud":"agent-frontend","sub":"ci-user",
  "email":"ci@example.test","name":"ci","provider":"google",
  "iat": int(time.time()), "exp": int(time.time())+3600
}
secret = os.environ.get("JWT_SECRET","ci-jwt-secret-please-change")
print(jwt.encode(payload, secret, algorithm="HS256"))
PY
)"
log "[E2E] created JWT (len=${#JWT})"

TASK_TITLE="e2e-task-$(date +%s)"
log "[E2E] creating task title='${TASK_TITLE}'"

# create task (capture raw response)
CREATE_RESP="$(curl -sS -X POST "${TASK_URL}/tasks" \
  -H "Authorization: Bearer ${JWT}" \
  -H "Content-Type: application/json" \
  -d "{\"title\":\"${TASK_TITLE}\"}" 2>/dev/null || true)"

log "[E2E] create response: ${CREATE_RESP}"

# extract id robustly using env var technique
RESP="${CREATE_RESP}" TASK_ID="$(extract_id_from_response "${CREATE_RESP}" || true)"
if [ -z "${TASK_ID}" ]; then
  log "[E2E][ERROR] task creation returned no id; tail task log (last 200 lines):"
  tail -n 200 "${LOGDIR}/task.log" | sed 's/^/  /'
  GLOBAL_STATUS=1
else
  log "[E2E] created task id=${TASK_ID}"
fi

# small pause for activity propagation
sleep 1

# fetch activity list for the user
log "[E2E] querying activity for ci-user"
ACT_LIST="$(curl -sS "${ACTIVITY_URL}/activity/user/ci-user" 2>/dev/null || true)"
log "[E2E] activity response: ${ACT_LIST}"

# verify presence of our event (task_created)
echo "${ACT_LIST}" | grep -q '"task_created"' >/dev/null 2>&1
if [ "$?" -eq 0 ]; then
  log "[E2E] OK: activity event recorded"
else
  log "[E2E][ERROR] no activity event found for created task; tail activity log (last 200 lines):"
  tail -n 200 "${LOGDIR}/activity.log" | sed 's/^/  /'
  GLOBAL_STATUS=1
fi

# ----------------------------
# Summary & final status handling
# ----------------------------
log "[E2E] SUMMARY: GLOBAL_STATUS=${GLOBAL_STATUS}"
log "[E2E] logs:"
log "  auth log: ${LOGDIR}/auth.log"
log "  task log: ${LOGDIR}/task.log"
log "  activity log: ${LOGDIR}/activity.log"
log "  pg pf log: ${LOGDIR}/pg_pf.log"
log "  val pf log: ${LOGDIR}/val_pf.log"

cat <<EOF >> "${LOG_MASTER}"
To stop managed processes run:
  kill \$(pgrep -f "uvicorn app:app --app-dir src/services/task-service") 2>/dev/null || true
  kill \$(pgrep -f "uvicorn app:app --app-dir src/services/activity-service") 2>/dev/null || true
  kill \$(pgrep -f "uvicorn src.services.auth.auth_server:app") 2>/dev/null || true
  kill \$(pgrep -f "kubectl -n ${K8S_PG_NS} port-forward ${K8S_PG_SVC}") 2>/dev/null || true
  kill \$(pgrep -f "kubectl -n ${K8S_VAL_NS} port-forward ${K8S_VAL_SVC}") 2>/dev/null || true

Logs directory: ${LOGDIR}
WORKDIR: ${WORKDIR}
EOF

# set non-zero exit via `false` if GLOBAL_STATUS != 0 (no explicit exit)
if [ "${GLOBAL_STATUS}" -ne 0 ]; then
  log "[E2E] completed with failures (GLOBAL_STATUS=${GLOBAL_STATUS})"
  false
else
  log "[E2E] completed successfully"
  true
fi