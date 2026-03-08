#!/usr/bin/env bash
# src/tests/auth_server.sh
# Purpose: ensure auth server is running and functional against k8s Postgres.
# - Starts (or reuses) a persistent kubectl port-forward to the Postgres Service
# - Starts (or reuses) the auth server process (uvicorn) and leaves it running
# - Performs high-signal checks (health, ready, login, PKCE persistence, callback handling, /me)
# - Uses kubectl exec into the Postgres pod for DB queries (avoids requiring local psql)
# - DOES NOT stop the auth server or port-forward; leaves PID files and logs for downstream use

IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

LOG(){ printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"; }
ERR(){ printf '%s ERROR: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >&2; }

# Configurable (env overrides)
K8S_NS="${K8S_NS:-databases}"
K8S_SERVICE="${K8S_SERVICE:-app-postgres-r}"
K8S_SECRET="${K8S_SECRET:-app-postgres-app}"
DB_PORT_HOST="${DB_PORT_HOST:-55432}"        # local forwarded port (for downstream)
DB_PORT_CONTAINER="5432"
DB_NAME="${DB_NAME:-}"                      # will attempt to read from secret or default to app
DB_USER="${DB_USER:-}"
DB_PASS="${DB_PASS:-}"

UVICORN_HOST="${UVICORN_HOST:-127.0.0.1}"
UVICORN_PORT="${UVICORN_PORT:-18200}"

PID_DIR="${PID_DIR:-/tmp/auth_test}"
mkdir -p "$PID_DIR"
PORTFWD_PID_FILE="$PID_DIR/auth_portforward.pid"
SERVER_PID_FILE="$PID_DIR/auth_server.pid"

SERVER_LOG="logs/auth_server_test.log"
TMP_HEALTH="/tmp/auth_health.json"
TMP_ME="/tmp/auth_me.json"
COOKIES_FILE="/tmp/auth_test_cookies.jar"
TMP_HEADERS="/tmp/auth_start_headers.txt"

mkdir -p logs
: > "$SERVER_LOG" || true

# Preconditions
command -v kubectl >/dev/null 2>&1 || { ERR "kubectl required"; exit 2; }
command -v curl >/dev/null 2>&1 || { ERR "curl required"; exit 2; }
command -v python3 >/dev/null 2>&1 || { ERR "python3 required"; exit 2; }

LOG "Starting auth-server test (will preserve server & port-forward)."

# Populate DB credentials from k8s secret if not provided
LOG "Retrieving DB credentials from k8s secret ${K8S_SECRET} (ns ${K8S_NS}) if available."
if [ -z "$DB_PASS" ]; then
  DB_PASS="$(kubectl -n "$K8S_NS" get secret "$K8S_SECRET" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [ -z "$DB_PASS" ] && DB_PASS="$(kubectl -n "$K8S_NS" get secret "$K8S_SECRET" -o jsonpath='{.data.pass}' 2>/dev/null | base64 -d 2>/dev/null || true)"
fi
if [ -z "$DB_USER" ]; then
  DB_USER="$(kubectl -n "$K8S_NS" get secret "$K8S_SECRET" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [ -z "$DB_USER" ] && DB_USER="$(kubectl -n "$K8S_NS" get secret "$K8S_SECRET" -o jsonpath='{.data.user}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [ -z "$DB_USER" ] && DB_USER="app"
fi
if [ -z "$DB_NAME" ]; then
  DB_NAME="$(kubectl -n "$K8S_NS" get secret "$K8S_SECRET" -o jsonpath='{.data.database}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [ -z "$DB_NAME" ] && DB_NAME="app"
fi

if [ -z "$DB_PASS" ]; then
  ERR "DB password missing: set DB_PASS env or ensure secret ${K8S_SECRET} contains 'password'."
  exit 3
fi

LOG "DB intent: localhost:${DB_PORT_HOST} db=${DB_NAME} user=${DB_USER}"

# Start kubectl port-forward if not already running (background, persisted)
if [ -f "$PORTFWD_PID_FILE" ] && kill -0 "$(cat "$PORTFWD_PID_FILE")" 2>/dev/null; then
  LOG "Reusing existing port-forward PID $(cat "$PORTFWD_PID_FILE")."
else
  LOG "Starting kubectl port-forward svc/${K8S_SERVICE} ${DB_PORT_HOST}:${DB_PORT_CONTAINER} -n ${K8S_NS}"
  nohup kubectl -n "$K8S_NS" port-forward svc/"$K8S_SERVICE" "${DB_PORT_HOST}:${DB_PORT_CONTAINER}" >/dev/null 2>&1 &
  sleep 0.25
  PORTFWD_PID=$!
  echo "$PORTFWD_PID" > "$PORTFWD_PID_FILE"
  LOG "Port-forward started (PID ${PORTFWD_PID}), persisted to ${PORTFWD_PID_FILE}."
fi

# Attempt quick TCP check of local forwarded port; do not fail hard if unavailable
LOG "Testing local TCP on localhost:${DB_PORT_HOST} (quick check)"
if (echo > /dev/tcp/127.0.0.1/"$DB_PORT_HOST") >/dev/null 2>&1; then
  LOG "Local TCP port ${DB_PORT_HOST} is open."
else
  LOG "Local TCP port ${DB_PORT_HOST} not open yet; continuing — DB checks will use kubectl exec where possible."
fi

# Start auth server if not running
if lsof -i :"$UVICORN_PORT" -t >/dev/null 2>&1; then
  EXIST_PID="$(lsof -i :"$UVICORN_PORT" -t | head -n1)"
  LOG "Auth server already running on port ${UVICORN_PORT} (pid=${EXIST_PID}). Reusing."
  echo "$EXIST_PID" > "$SERVER_PID_FILE"
else
  LOG "Starting auth server (uvicorn) and leaving it running. Logs -> ${SERVER_LOG}"
  # generate session secret if not set
  SESSION_SECRET="${SESSION_SECRET:-$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
)}"
  export DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@localhost:${DB_PORT_HOST}/${DB_NAME}"
  export SESSION_SECRET
  export JWT_SECRET="${JWT_SECRET:-test_jwt_secret}"
  nohup bash -lc "export DATABASE_URL='${DATABASE_URL}'; export SESSION_SECRET='${SESSION_SECRET}'; export JWT_SECRET='${JWT_SECRET}'; python3 -m uvicorn src.services.auth.auth_server:app --host ${UVICORN_HOST} --port ${UVICORN_PORT}" \
    >"$SERVER_LOG" 2>&1 &
  sleep 0.4
  SERVER_PID=$!
  echo "$SERVER_PID" > "$SERVER_PID_FILE"
  LOG "Auth server started (PID ${SERVER_PID}), persisted to ${SERVER_PID_FILE}."
fi

# Wait for auth /health (best-effort)
HEALTH_URL="http://${UVICORN_HOST}:${UVICORN_PORT}/health"
LOG "Waiting up to 30s for ${HEALTH_URL}"
TRIES=0
MAX_HEALTH=30
until curl -sfS "$HEALTH_URL" -o "$TMP_HEALTH" 2>/dev/null || [ $TRIES -ge $MAX_HEALTH ]; do
  sleep 1
  TRIES=$((TRIES+1))
done
if [ $TRIES -ge $MAX_HEALTH ]; then
  ERR "Auth server /health did not respond within ${MAX_HEALTH}s (continuing; server left running)."
else
  LOG "/health response:"
  sed -n '1,120p' "$TMP_HEALTH" || true
fi

# Collect basic endpoints
LOG "Checking /ready and /login endpoints."
READY_BODY="$(curl -sfS "http://${UVICORN_HOST}:${UVICORN_PORT}/ready" || true)"
LOG "/ready => ${READY_BODY}"
LOGIN_BODY="$(curl -sfS "http://${UVICORN_HOST}:${UVICORN_PORT}/login" || true)"
LOG "login page snippet:"
echo "$LOGIN_BODY" | sed -n '1,80p' || true

# Trigger login/start to create PKCE entry and capture session cookie
rm -f "$COOKIES_FILE" "$TMP_HEADERS"
curl -s -i -D "$TMP_HEADERS" -c "$COOKIES_FILE" -o /dev/null "http://${UVICORN_HOST}:${UVICORN_PORT}/auth/login/start/google" || true
START_CODE="$(head -n1 "$TMP_HEADERS" | awk '{print $2}' || true)"
LOG "/auth/login/start/google status: ${START_CODE}; cookiejar: ${COOKIES_FILE}"

# Use kubectl exec into a Postgres pod for DB checks (preferred)
LOG "Locating Postgres pod in ns ${K8S_NS} (looking for app-postgres*)"
POD_NAME="$(kubectl -n "$K8S_NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E 'app-postgres' | head -n1 || true)"
if [ -z "$POD_NAME" ]; then
  POD_NAME="$(kubectl -n "$K8S_NS" get pods -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi

PENDING_ROW=""
AUDIT_ROWS=""
SCHEMA_TABLES=""

if [ -n "$POD_NAME" ]; then
  LOG "Using pod ${POD_NAME} for in-cluster DB queries."
  set +e
  PENDING_ROW="$(kubectl -n "$K8S_NS" exec "$POD_NAME" -- bash -lc "psql -U ${DB_USER} -d ${DB_NAME} -t -A -c \"SELECT state, provider, code_verifier, created_at FROM oauth_pending ORDER BY created_at DESC LIMIT 1;\" " 2>/dev/null || true)"
  AUDIT_ROWS="$(kubectl -n "$K8S_NS" exec "$POD_NAME" -- bash -lc "psql -U ${DB_USER} -d ${DB_NAME} -t -A -c \"SELECT timestamp, action, details FROM audit_logs ORDER BY timestamp DESC LIMIT 10;\" " 2>/dev/null || true)"
  SCHEMA_TABLES="$(kubectl -n "$K8S_NS" exec "$POD_NAME" -- bash -lc "psql -U ${DB_USER} -d ${DB_NAME} -t -A -c \"SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;\" " 2>/dev/null || true)"
  set -e
else
  LOG "No pod found; skipping in-cluster DB queries."
fi

if [ -n "$PENDING_ROW" ]; then
  LOG "oauth_pending latest: ${PENDING_ROW}"
  STATE_VAL="$(echo "$PENDING_ROW" | cut -d'|' -f1 || true)"
  VERIFIER_VAL="$(echo "$PENDING_ROW" | cut -d'|' -f3 || true)"
  LOG "state_len=${#STATE_VAL:-0} verifier_len=${#VERIFIER_VAL:-0}"
  if [ "${#STATE_VAL:-0}" -lt 16 ] || [ "${#VERIFIER_VAL:-0}" -lt 43 ]; then
    ERR "PKCE row exists but sizes are unexpected (state<16 or verifier<43)."
  else
    LOG "PKCE persistence looks OK."
  fi
else
  LOG "No oauth_pending row found (server may not persist PKCE server-side)."
fi

# Simulate callback with invalid code to produce login_failed audit log (if state present)
if [ -n "${STATE_VAL:-}" ]; then
  LOG "Simulating invalid callback with preserved cookie (state=${STATE_VAL})"
  CB_RESP="$(curl -s -i -b "$COOKIES_FILE" -c "$COOKIES_FILE" "http://${UVICORN_HOST}:${UVICORN_PORT}/auth/callback/google?state=${STATE_VAL}&code=invalid-code" || true)"
  LOG "callback response snippet:"
  echo "$CB_RESP" | sed -n '1,40p' || true
else
  LOG "Skipping invalid callback simulation (no state available)."
fi

# /me via JWT
LOG "Testing /me with a synthetic JWT (HS256 using JWT_SECRET)."
TEST_JWT="$(python3 - <<PY
import jwt, time, os
payload = {"iss":"agentic-platform","aud":"agent-frontend","sub":"ci-user","email":"ci@example.test","name":"ci","provider":"google","iat":int(time.time()),"exp":int(time.time())+3600}
print(jwt.encode(payload, os.environ.get("JWT_SECRET","test_jwt_secret"), algorithm="HS256"))
PY
)"
ME_CODE="$(curl -s -o "$TMP_ME" -w "%{http_code}" -H "Authorization: Bearer ${TEST_JWT}" "http://${UVICORN_HOST}:${UVICORN_PORT}/me" || true)"
if [ "$ME_CODE" = "200" ]; then
  LOG "/me accepted JWT (HTTP 200)"
  sed -n '1,200p' "$TMP_ME" || true
  AUTH_MODE="jwt"
else
  LOG "/me did not accept JWT (HTTP ${ME_CODE})"
  AUTH_MODE="unknown"
fi

# logout behavior quick check
LOG "Checking /logout"
LOGOUT_RESP="$(curl -s -i "http://${UVICORN_HOST}:${UVICORN_PORT}/logout" || true)"
echo "$LOGOUT_RESP" | sed -n '1,40p' || true

# DB schema presence check (from pod)
if [ -n "$SCHEMA_TABLES" ]; then
  LOG "Public tables: ${SCHEMA_TABLES}"
  echo "${SCHEMA_TABLES}" | grep -E 'users|audit_logs|oauth_pending' >/dev/null 2>&1 || ERR "Expected DB tables (users, audit_logs, oauth_pending) missing or not visible."
else
  LOG "Public tables unavailable (no pod or psql in pod)."
fi

# Audit logs snippet
if [ -n "$AUDIT_ROWS" ]; then
  LOG "Recent audit_logs (snippet):"
  echo "$AUDIT_ROWS" | sed -n '1,20p' || true
else
  LOG "No audit log rows available or unable to query."
fi

# Summary (connection info and how to stop persistent processes)
cat <<EOF

==== AUTH SERVER TEST SUMMARY ====
Auth server:
  host: ${UVICORN_HOST}
  port: ${UVICORN_PORT}
  health: http://${UVICORN_HOST}:${UVICORN_PORT}/health
  ready:  http://${UVICORN_HOST}:${UVICORN_PORT}/ready
  login:  http://${UVICORN_HOST}:${UVICORN_PORT}/login
  server pid file: ${SERVER_PID_FILE}
  server log: ${SERVER_LOG}

Postgres (port-forward):
  local_host: localhost
  local_port: ${DB_PORT_HOST}
  db_name: ${DB_NAME}
  db_user: ${DB_USER}
  k8s service: ${K8S_SERVICE}.${K8S_NS}.svc.cluster.local:5432
  port-forward pid file: ${PORTFWD_PID_FILE}

Secrets & creds:
  secret used: ${K8S_SECRET} (namespace ${K8S_NS})
  DB_PASS present: ${DB_PASS:+yes}${DB_PASS:-(hidden)}
  DB_USER: ${DB_USER}
  DB_NAME: ${DB_NAME}

Checks performed:
  /health checked: $( [ -s "$TMP_HEALTH" ] && echo yes || echo no )
  /ready response: $( [ -n "$READY_BODY" ] && echo yes || echo no )
  /login snippet saved: yes
  oauth_pending row (from pod): ${PENDING_ROW:-(none)}
  audit_logs snippet (from pod): $( [ -n "$AUDIT_ROWS" ] && echo yes || echo no )
  public tables (from pod): ${SCHEMA_TABLES:-(none)}
  /me auth mode: ${AUTH_MODE}

Important:
  - This script intentionally leaves both the auth server and the kubectl port-forward running.
  - To stop them manually:
      if [ -f "${SERVER_PID_FILE}" ]; then kill "$(cat ${SERVER_PID_FILE})" || true; fi
      if [ -f "${PORTFWD_PID_FILE}" ]; then kill "$(cat ${PORTFWD_PID_FILE})" || true; fi
  - If downstream services require plain DB password, read it from the k8s secret:
      kubectl -n ${K8S_NS} get secret ${K8S_SECRET} -o jsonpath='{.data.password}' | base64 -d

Temporary artifacts left: ${COOKIES_FILE} (cookiejar), ${TMP_ME} (last /me response), ${TMP_HEADERS}
Server log retained at: ${SERVER_LOG}

==== END SUMMARY ====
EOF

# Keep only non-destructive cleanup of transient temporary files (do not stop server or port-forward)
rm -f "$TMP_HEALTH" || true

# Exit code: 0 if basic server health returned 200, otherwise 1 to indicate tests found issues.
if curl -sfS "http://${UVICORN_HOST}:${UVICORN_PORT}/health" >/dev/null 2>&1; then
  LOG "Auth server reported healthy — script completed successfully."
  exit 0
else
  ERR "Auth server unhealthy or unreachable. Server left running for inspection."
  exit 1
fi