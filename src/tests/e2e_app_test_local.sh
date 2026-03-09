#!/usr/bin/env bash
# src/tests/e2e_app_test_local.sh
# Hardened, idempotent E2E smoke test with SigNoz port-forwarding.
# Run with: bash src/tests/e2e_app_test_local.sh

WORKDIR="${WORKDIR:-/tmp/e2e_app_test}"
LOGDIR="${LOGDIR:-${WORKDIR}/logs}"
mkdir -p "$WORKDIR" "$LOGDIR"

DESIRED_PG_PORT="${DESIRED_PG_PORT:-55432}"
DESIRED_VAL_PORT="${DESIRED_VAL_PORT:-6379}"

K8S_PG_SVC="${K8S_PG_SVC:-svc/app-postgres-r}"
K8S_PG_NS="${K8S_PG_NS:-databases}"
K8S_VAL_SVC="${K8S_VAL_SVC:-svc/valkey}"
K8S_VAL_NS="${K8S_VAL_NS:-valkey-prod}"

K8S_SIGNOZ_NS="${K8S_SIGNOZ_NS:-signoz}"
K8S_SIGNOZ_UI_SVC="${K8S_SIGNOZ_UI_SVC:-svc/signoz}"
K8S_SIGNOZ_OTEL_SVC="${K8S_SIGNOZ_OTEL_SVC:-svc/signoz-otel-collector}"
DESIRED_SIGNOZ_UI_PORT="${DESIRED_SIGNOZ_UI_PORT:-3301}"
DESIRED_SIGNOZ_OTEL_PORT="${DESIRED_SIGNOZ_OTEL_PORT:-4317}"

AUTH_HOST="${AUTH_HOST:-127.0.0.1}"
AUTH_PORT="${AUTH_PORT:-18200}"
AUTH_URL="http://${AUTH_HOST}:${AUTH_PORT}"
ACTIVITY_PORT="${ACTIVITY_PORT:-8002}"
TASK_PORT="${TASK_PORT:-8001}"
ACTIVITY_URL="http://127.0.0.1:${ACTIVITY_PORT}"
TASK_URL="http://127.0.0.1:${TASK_PORT}"

PORTFWD_RETRIES="${PORTFWD_RETRIES:-4}"
PORTFWD_BACKOFF_SECONDS="${PORTFWD_BACKOFF_SECONDS:-1}"
PORT_CHECK_TIMEOUT="${PORT_CHECK_TIMEOUT:-20}"
HEALTH_WAIT="${HEALTH_WAIT:-30}"

KEEP_RUNNING_ON_EXIT="${KEEP_RUNNING_ON_EXIT:-0}"

pidfile() { printf "%s/%s.pid" "$WORKDIR" "$1"; }
portfile() { printf "%s/%s.port" "$WORKDIR" "$1"; }

LOG_MASTER="${LOGDIR}/e2e_master.log"
log() { printf "%s %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_MASTER"; }

# prerequisites (non-fatal)
_requirements_ok=0
for cmd in kubectl python3 curl uvicorn; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "[WARN] missing command in PATH: $cmd"
    _requirements_ok=1
  fi
done
if [ "$_requirements_ok" -ne 0 ]; then
  log "[WARN] some required CLI tools are missing; script will continue but may fail"
fi

# helpers
is_pid_running() { local pid="$1"; [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; }
write_pid() { local name="$1" pid="$2"; printf "%s" "$pid" > "$(pidfile "$name")"; }
read_pidfile() { local name="$1"; [ -f "$(pidfile "$name")" ] && cat "$(pidfile "$name")" || echo ""; }
write_port() { local name="$1" port="$2"; printf "%s" "$port" > "$(portfile "$name")"; }
read_portfile() { local name="$1"; [ -f "$(portfile "$name")" ] && cat "$(portfile "$name")" || echo ""; }

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

redis_ping() {
  local host="${1:-127.0.0.1}" port="${2:-6379}" timeout="${3:-2}"
  python3 - "$host" "$port" "$timeout" <<'PY' >/dev/null 2>&1 || true
import sys, socket
h=sys.argv[1]; p=int(sys.argv[2]); to=int(sys.argv[3])
try:
    s=socket.create_connection((h,p), timeout=to)
    s.sendall(b"*1\r\n$4\r\nPING\r\n")
    r=s.recv(512)
    s.close()
    if b"PONG" in r or r.startswith(b"+PONG"): sys.exit(0)
    sys.exit(2)
except Exception:
    sys.exit(3)
PY
  return $?
}

extract_id_from_response() {
  local raw="$1"
  python3 - "$raw" <<'PY' 2>/dev/null || true
import sys, json
raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    if not raw:
        print("")
        sys.exit(0)
    data = json.loads(raw)
    v = data.get("id", "")
    if v is None:
        v = ""
    print(v)
except Exception:
    print("")
PY
}

# safe kill (portable)
safe_kill_cmd_pattern() {
  local pattern="$1"
  pids=$(pgrep -f "$pattern" 2>/dev/null || true)
  if [ -z "$pids" ]; then
    return 0
  fi
  for pid in $pids; do
    if [ -z "$pid" ]; then continue; fi
    cmdline="$(ps -p "$pid" -o cmd= 2>/dev/null || echo "")"
    if printf '%s\n' "$cmdline" | grep -F -- "$pattern" >/dev/null 2>&1; then
      log "[CLEAN] killing pid=${pid} pattern verified -> cmd: ${cmdline}"
      kill "$pid" >/dev/null 2>&1 || true
      sleep 0.15
      if is_pid_running "$pid"; then kill -9 "$pid" >/dev/null 2>&1 || true; fi
    else
      log "[CLEAN] skipping pid=${pid} cmdline mismatch: ${cmdline}"
    fi
  done
  return 0
}

cleanup_pid_and_port_files() { local name="$1"; rm -f "$(pidfile "$name")" "$(portfile "$name")" 2>/dev/null || true; }

cleanup_all() {
  log "[CLEAN] cleanup_all invoked"
  if [ "${KEEP_RUNNING_ON_EXIT}" = "1" ]; then
    log "[CLEAN] KEEP_RUNNING_ON_EXIT=1 - leaving processes running"
    return 0
  fi

  safe_kill_cmd_pattern "kubectl -n ${K8S_PG_NS} port-forward ${K8S_PG_SVC}" || true
  safe_kill_cmd_pattern "kubectl -n ${K8S_VAL_NS} port-forward ${K8S_VAL_SVC}" || true
  safe_kill_cmd_pattern "kubectl -n ${K8S_SIGNOZ_NS} port-forward ${K8S_SIGNOZ_UI_SVC}" || true
  safe_kill_cmd_pattern "kubectl -n ${K8S_SIGNOZ_NS} port-forward ${K8S_SIGNOZ_OTEL_SVC}" || true
  safe_kill_cmd_pattern "uvicorn src.services.task_service.app:app" || true
  safe_kill_cmd_pattern "uvicorn src.services.activity_service.app:app" || true
  safe_kill_cmd_pattern "uvicorn src.services.auth.app:app" || true

  cleanup_pid_and_port_files "pg_pf"
  cleanup_pid_and_port_files "val_pf"
  cleanup_pid_and_port_files "signoz_ui_pf"
  cleanup_pid_and_port_files "signoz_otel_pf"
  cleanup_pid_and_port_files "auth"
  cleanup_pid_and_port_files "task"
  cleanup_pid_and_port_files "activity"

  log "[CLEAN] cleanup_all complete"
}

trap 'cleanup_all' EXIT

log "[E2E] start; workdir=${WORKDIR}"
date -u +"%Y-%m-%dT%H:%M:%SZ" | tee -a "$LOG_MASTER"

log "[E2E] pre-clean: stopping known previous test processes (safe matches)"
safe_kill_cmd_pattern "kubectl -n ${K8S_PG_NS} port-forward ${K8S_PG_SVC}" || true
safe_kill_cmd_pattern "kubectl -n ${K8S_VAL_NS} port-forward ${K8S_VAL_SVC}" || true
safe_kill_cmd_pattern "kubectl -n ${K8S_SIGNOZ_NS} port-forward ${K8S_SIGNOZ_UI_SVC}" || true
safe_kill_cmd_pattern "kubectl -n ${K8S_SIGNOZ_NS} port-forward ${K8S_SIGNOZ_OTEL_SVC}" || true
safe_kill_cmd_pattern "uvicorn src.services.task_service.app:app" || true
safe_kill_cmd_pattern "uvicorn src.services.activity_service.app:app" || true
safe_kill_cmd_pattern "uvicorn src.services.auth.app:app" || true

: > "${LOGDIR}/pg_pf.log" 2>/dev/null || true
: > "${LOGDIR}/val_pf.log" 2>/dev/null || true
: > "${LOGDIR}/auth.log" 2>/dev/null || true
: > "${LOGDIR}/task.log" 2>/dev/null || true
: > "${LOGDIR}/activity.log" 2>/dev/null || true
: > "${LOGDIR}/signoz_ui_pf.log" 2>/dev/null || true
: > "${LOGDIR}/signoz_otel_pf.log" 2>/dev/null || true

GLOBAL_STATUS=0

# port-forward manager
start_or_reuse_port_forward() {
  local ns="$1" svc="$2" desired_port="$3" remote_port="$4" name="$5" outlog="$6"
  local existing_pid existing_port pid_local local_port attempt

  existing_pid="$(read_pidfile "$name" || true)"
  existing_port="$(read_portfile "$name" || true)"

  if [ -n "$existing_pid" ] && is_pid_running "$existing_pid"; then
    if [ -n "$existing_port" ] && port_is_listening 127.0.0.1 "$existing_port" 1; then
      log "[E2E] reusing existing port-forward pid=${existing_pid} for ${svc} -> localhost:${existing_port}"
      return 0
    else
      log "[E2E] found stale pidfile for ${name}; cleaning"
      cleanup_pid_and_port_files "$name"
    fi
  fi

  attempt=0
  local_port="$desired_port"
  while [ "$attempt" -lt "$PORTFWD_RETRIES" ]; do
    attempt=$((attempt + 1))
    if port_is_listening 127.0.0.1 "$local_port" 0; then
      log "[E2E] desired local port ${local_port} in use; picking ephemeral port"
      local_port="$(find_free_port)"
      log "[E2E] will try ephemeral local port ${local_port}"
    fi

    log "[E2E] starting kubectl port-forward attempt ${attempt}/${PORTFWD_RETRIES}: ${svc} ${ns} -> localhost:${local_port}"
    ( kubectl -n "${ns}" port-forward "${svc}" "${local_port}:${remote_port}" > "${outlog}" 2>&1 ) &
    pid_local=$!
    sleep 0.5

    if ! is_pid_running "${pid_local}"; then
      log "[E2E] port-forward exited quickly; excerpt:"
      tail -n 200 "${outlog}" | sed -n '1,200p' | sed 's/^/  /'
      cleanup_pid_and_port_files "$name"
      sleep "${PORTFWD_BACKOFF_SECONDS}"
      continue
    fi

    write_pid "$name" "$pid_local"
    write_port "$name" "$local_port"

    if port_is_listening 127.0.0.1 "$local_port" "${PORT_CHECK_TIMEOUT}"; then
      log "[E2E] port-forward established pid=${pid_local} local_port=${local_port}"
      return 0
    fi

    log "[E2E] port ${local_port} not listening after wait; killing pf pid=${pid_local}"
    kill "${pid_local}" >/dev/null 2>&1 || true
    cleanup_pid_and_port_files "$name"
    sleep "${PORTFWD_BACKOFF_SECONDS}"
  done

  log "[E2E] failed to establish port-forward for ${svc}; check ${outlog}"
  return 1
}

log "[E2E] ensuring Postgres port-forward"
if start_or_reuse_port_forward "${K8S_PG_NS}" "${K8S_PG_SVC}" "${DESIRED_PG_PORT}" 5432 "pg_pf" "${LOGDIR}/pg_pf.log"; then
  PG_PF_PORT_ACTUAL="$(read_portfile pg_pf)"
  log "[E2E] postgres available at 127.0.0.1:${PG_PF_PORT_ACTUAL}"
else
  log "[E2E][WARN] postgres port-forward failed; DB calls may fail"
  PG_PF_PORT_ACTUAL=""
  GLOBAL_STATUS=1
fi

log "[E2E] ensuring Valkey port-forward"
if start_or_reuse_port_forward "${K8S_VAL_NS}" "${K8S_VAL_SVC}" "${DESIRED_VAL_PORT}" 6379 "val_pf" "${LOGDIR}/val_pf.log"; then
  VAL_PF_PORT_ACTUAL="$(read_portfile val_pf)"
  log "[E2E] valkey available at 127.0.0.1:${VAL_PF_PORT_ACTUAL}"
else
  log "[E2E][WARN] valkey port-forward failed; cache unavailable"
  VAL_PF_PORT_ACTUAL=""
  GLOBAL_STATUS=1
fi

log "[E2E] ensuring SigNoz UI port-forward"
if start_or_reuse_port_forward "${K8S_SIGNOZ_NS}" "${K8S_SIGNOZ_UI_SVC}" "${DESIRED_SIGNOZ_UI_PORT}" 8080 "signoz_ui_pf" "${LOGDIR}/signoz_ui_pf.log"; then
  SIGNOZ_UI_PORT_ACTUAL="$(read_portfile signoz_ui_pf)"
  log "[E2E] signoz UI available at http://127.0.0.1:${SIGNOZ_UI_PORT_ACTUAL}"
else
  log "[E2E][WARN] signoz UI port-forward failed; observability offline"
  SIGNOZ_UI_PORT_ACTUAL=""
  GLOBAL_STATUS=1
fi

log "[E2E] ensuring SigNoz OTLP collector port-forward"
if start_or_reuse_port_forward "${K8S_SIGNOZ_NS}" "${K8S_SIGNOZ_OTEL_SVC}" "${DESIRED_SIGNOZ_OTEL_PORT}" 4317 "signoz_otel_pf" "${LOGDIR}/signoz_otel_pf.log"; then
  SIGNOZ_OTEL_PORT_ACTUAL="$(read_portfile signoz_otel_pf)"
  log "[E2E] signoz OTLP collector available at 127.0.0.1:${SIGNOZ_OTEL_PORT_ACTUAL}"
else
  log "[E2E][WARN] signoz OTLP port-forward failed; telemetry may not arrive"
  SIGNOZ_OTEL_PORT_ACTUAL=""
  GLOBAL_STATUS=1
fi

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

if [ -n "${SIGNOZ_OTEL_PORT_ACTUAL}" ]; then
  export OTEL_EXPORTER_OTLP_ENDPOINT="127.0.0.1:${SIGNOZ_OTEL_PORT_ACTUAL}"
  export OTEL_EXPORTER_OTLP_INSECURE="true"
  export OTEL_PYTHON_LOG_LEVEL="${OTEL_PYTHON_LOG_LEVEL:-INFO}"
  log "[E2E] exported OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_EXPORTER_OTLP_ENDPOINT}"
fi

export JWT_SECRET="${JWT_SECRET:-ci-jwt-secret-please-change}"
export SESSION_SECRET="${SESSION_SECRET:-ci-session-secret-please-change}"

start_service_if_needed() {
  local name="$1" local_cmd="$2" logf="$3"
  local existing_pid cmdline pid
  existing_pid="$(read_pidfile "$name" || true)"
  if [ -n "$existing_pid" ] && is_pid_running "$existing_pid"; then
    cmdline="$(ps -p "$existing_pid" -o cmd= 2>/dev/null || echo "")"
    if printf '%s\n' "$cmdline" | grep -F -- "$local_cmd" >/dev/null 2>&1 || printf '%s\n' "$cmdline" | grep -F -- "$(echo "$local_cmd" | awk '{print $1}')" >/dev/null 2>&1; then
      log "[E2E] reusing running service $name pid=${existing_pid}"
      return 0
    else
      log "[E2E] found stale pidfile for service $name pid=${existing_pid}; removing"
      cleanup_pid_and_port_files "$name"
    fi
  fi

  log "[E2E] starting service $name (logs -> ${logf})"
  ( eval "${local_cmd}" >> "${logf}" 2>&1 ) &
  pid=$!
  sleep 0.45

  if ! is_pid_running "$pid"; then
    log "[E2E][ERROR] service $name failed to start; tail log (last 200 lines):"
    tail -n 200 "${logf}" | sed 's/^/  /'
    GLOBAL_STATUS=1
    return 1
  fi

  write_pid "$name" "$pid"
  log "[E2E] service $name started pid=${pid}"
  return 0
}

start_service_if_needed "auth" "uvicorn src.services.auth.app:app --host ${AUTH_HOST} --port ${AUTH_PORT} --log-level info" "${LOGDIR}/auth.log"
start_service_if_needed "activity" "uvicorn src.services.activity_service.app:app --host 127.0.0.1 --port ${ACTIVITY_PORT} --log-level info" "${LOGDIR}/activity.log"
start_service_if_needed "task" "uvicorn src.services.task_service.app:app --host 127.0.0.1 --port ${TASK_PORT} --log-level info" "${LOGDIR}/task.log"

wait_for_http_ok() {
  local url="$1" timeout="${2:-30}"
  local i=0
  while [ "$i" -lt "$timeout" ]; do
    if curl -sS --max-time 3 "$url" >/dev/null 2>&1; then return 0; fi
    i=$((i+1)); sleep 1
  done
  return 1
}

log "[E2E] waiting for auth /health"
if wait_for_http_ok "${AUTH_URL}/health" "${HEALTH_WAIT}"; then log "[E2E] auth healthy"; else log "[E2E][ERROR] auth /health not healthy after wait; tail auth log (last 200 lines):"; tail -n 200 "${LOGDIR}/auth.log" | sed 's/^/  /'; GLOBAL_STATUS=1; fi

log "[E2E] waiting for activity /health"
if wait_for_http_ok "${ACTIVITY_URL}/health" "${HEALTH_WAIT}"; then log "[E2E] activity healthy"; else log "[E2E][ERROR] activity /health not healthy after wait; tail activity log (last 200 lines):"; tail -n 200 "${LOGDIR}/activity.log" | sed 's/^/  /'; GLOBAL_STATUS=1; fi

log "[E2E] waiting for task /health"
if wait_for_http_ok "${TASK_URL}/health" "${HEALTH_WAIT}"; then log "[E2E] task healthy"; else log "[E2E][ERROR] task /health not healthy after wait; tail task log (last 200 lines):"; tail -n 200 "${LOGDIR}/task.log" | sed 's/^/  /'; GLOBAL_STATUS=1; fi

log "[E2E] generating JWT"
JWT="$(python3 - <<'PY'
import jwt, time, os
payload = {
  "iss":"agentic-platform","aud":"agent-frontend","sub":"ci-user",
  "email":"ci@example.test","name":"ci","provider":"google",
  "iat": int(time.time()), "exp": int(time.time())+3600
}
secret = os.environ.get("JWT_SECRET","ci-jwt-secret-please-change")
print(jwt.encode(payload, secret, algorithm="HS256"))
PY
)"
log "[E2E] created JWT length=${#JWT}"

TASK_TITLE="e2e-task-$(date +%s)"
log "[E2E] creating task title='${TASK_TITLE}'"

CREATE_RESP="$(curl -sS -X POST "${TASK_URL}/tasks" \
  -H "Authorization: Bearer ${JWT}" \
  -H "Content-Type: application/json" \
  -d "{\"title\":\"${TASK_TITLE}\"}" 2>/dev/null || true)"

log "[E2E] create response: ${CREATE_RESP}"

TASK_ID="$(extract_id_from_response "${CREATE_RESP}" || true)"
if [ -z "${TASK_ID}" ]; then
  log "[E2E][ERROR] task creation returned no id; tail task log (last 200 lines):"
  tail -n 200 "${LOGDIR}/task.log" | sed 's/^/  /'
  GLOBAL_STATUS=1
else
  log "[E2E] created task id=${TASK_ID}"
fi

sleep 1

log "[E2E] querying activity for ci-user"
ACT_LIST="$(curl -sS "${ACTIVITY_URL}/activity/user/ci-user" 2>/dev/null || true)"
log "[E2E] activity response: ${ACT_LIST}"

echo "${ACT_LIST}" | grep -q '"task_created"' >/dev/null 2>&1
if [ "$?" -eq 0 ]; then
  log "[E2E] OK: activity event recorded"
else
  log "[E2E][ERROR] no activity event found for created task; tail activity log (last 200 lines):"
  tail -n 200 "${LOGDIR}/activity.log" | sed 's/^/  /'
  GLOBAL_STATUS=1
fi

log "[E2E] SUMMARY: GLOBAL_STATUS=${GLOBAL_STATUS}"
log "[E2E] logs:"
log "  auth log: ${LOGDIR}/auth.log"
log "  task log: ${LOGDIR}/task.log"
log "  activity log: ${LOGDIR}/activity.log"
log "  pg pf log: ${LOGDIR}/pg_pf.log"
log "  val pf log: ${LOGDIR}/val_pf.log"
log "  signoz ui pf log: ${LOGDIR}/signoz_ui_pf.log"
log "  signoz otel pf log: ${LOGDIR}/signoz_otel_pf.log"

cat <<EOF >> "${LOG_MASTER}"
To stop managed processes run:
  kill \$(pgrep -f "uvicorn src.services.task_service.app:app") 2>/dev/null || true
  kill \$(pgrep -f "uvicorn src.services.activity_service.app:app") 2>/dev/null || true
  kill \$(pgrep -f "uvicorn src.services.auth.app:app") 2>/dev/null || true
  kill \$(pgrep -f "kubectl -n ${K8S_PG_NS} port-forward ${K8S_PG_SVC}") 2>/dev/null || true
  kill \$(pgrep -f "kubectl -n ${K8S_VAL_NS} port-forward ${K8S_VAL_SVC}") 2>/dev/null || true
  kill \$(pgrep -f "kubectl -n ${K8S_SIGNOZ_NS} port-forward ${K8S_SIGNOZ_UI_SVC}") 2>/dev/null || true
  kill \$(pgrep -f "kubectl -n ${K8S_SIGNOZ_NS} port-forward ${K8S_SIGNOZ_OTEL_SVC}") 2>/dev/null || true

SigNoz UI (if forwarded): http://127.0.0.1:${SIGNOZ_UI_PORT_ACTUAL:-${DESIRED_SIGNOZ_UI_PORT}}
OTLP endpoint (if forwarded): ${OTEL_EXPORTER_OTLP_ENDPOINT:-not_set}

Logs directory: ${LOGDIR}
WORKDIR: ${WORKDIR}
EOF

if [ "${GLOBAL_STATUS}" -ne 0 ]; then
  log "[E2E] completed with failures (GLOBAL_STATUS=${GLOBAL_STATUS})"
  false
else
  log "[E2E] completed successfully"
  true
fi
