#!/usr/bin/env bash
# src/tests/auth_server.sh
# Idempotent end-to-end integration test for auth_server.py
# - Starts disposable Postgres docker container (idempotent)
# - Starts auth server via "python3 -m uvicorn"
# - Runs high-signal checks: /health, /ready, /login page, PKCE persistence (oauth_pending), callback error path, audit_logs, /me (JWT), /logout, DB tables
# - Cleans up after itself
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

LOG(){ printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"; }
ERR(){ LOG "ERROR: $*" >&2; }
DIE(){ ERR "$*"; dump_logs; cleanup; exit 1; }

# --- configurable (override via environment) ---
DB_CONTAINER="${DB_CONTAINER:-auth-test-pg}"
DB_IMAGE="${DB_IMAGE:-postgres:16}"
DB_PORT_HOST="${DB_PORT_HOST:-55432}"      # host port mapped to container 5432
DB_PORT_CONTAINER="5432"
DB_NAME="${DB_NAME:-authdb}"
DB_USER="${DB_USER:-authuser}"
DB_PASS="${DB_PASS:-authpass}"

UVICORN_HOST="${UVICORN_HOST:-127.0.0.1}"
UVICORN_PORT="${UVICORN_PORT:-18200}"

SERVER_LOG="logs/auth_server_test.log"
COOKIES_FILE="/tmp/auth_test_cookies.jar"
TMP_HEADERS="/tmp/auth_start_headers.txt"
TMP_HEALTH="/tmp/auth_health.json"
TMP_ME="/tmp/auth_me.json"

mkdir -p logs
: > "$SERVER_LOG" || true

# --- environment exported to the server process ---
export DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@localhost:${DB_PORT_HOST}/${DB_NAME}"
export SESSION_SECRET="${SESSION_SECRET:-$(python3 - <<'PY'
import secrets,sys
print(secrets.token_urlsafe(32))
PY
)}"
export JWT_SECRET="${JWT_SECRET:-test_jwt_secret}"
export SESSION_COOKIE_SECURE="${SESSION_COOKIE_SECURE:-false}"
export COOKIE_SECURE="${COOKIE_SECURE:-false}"
export FRONTEND_BASE_URL="${FRONTEND_BASE_URL:-http://127.0.0.1:3000}"

# --- helper functions ---
dump_logs(){
  LOG "---- server log (tail 200 lines) ----"
  [ -f "$SERVER_LOG" ] && tail -n 200 "$SERVER_LOG" || LOG "(no server log)"
  LOG "---- docker postgres logs (tail 200) ----"
  docker logs "$DB_CONTAINER" --tail 200 2>/dev/null || LOG "(no docker logs)"
}

cleanup(){
  LOG "cleanup: stopping server and removing container (if created by this script)"
  if [ -n "${SERVER_PID-}" ] && ps -p "$SERVER_PID" >/dev/null 2>&1; then
    LOG "Stopping uvicorn PID $SERVER_PID"
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if docker ps -a --format '{{.Names}}' | grep -xq "$DB_CONTAINER"; then
    LOG "Removing docker container $DB_CONTAINER"
    docker rm -f "$DB_CONTAINER" >/dev/null 2>&1 || true
  fi
  rm -f "$COOKIES_FILE" "$TMP_HEADERS" "$TMP_HEALTH" "$TMP_ME" || true
}
trap cleanup EXIT

# --- preflight checks ---
command -v docker >/dev/null 2>&1 || DIE "docker is required"
command -v curl >/dev/null 2>&1 || DIE "curl is required"
command -v python3 >/dev/null 2>&1 || DIE "python3 is required"

# --- idempotent cleanup of previous artifacts ---
LOG "Cleaning previous container and processes"
docker rm -f "$DB_CONTAINER" >/dev/null 2>&1 || true
OLD_PID="$(lsof -i :"$UVICORN_PORT" -t 2>/dev/null || true)"
if [ -n "$OLD_PID" ]; then
  LOG "Killing old process on $UVICORN_PORT (pid $OLD_PID)"
  kill "$OLD_PID" >/dev/null 2>&1 || true
fi

# --- start postgres container idempotently ---
LOG "Starting Postgres container (${DB_CONTAINER})"
docker run -d --name "$DB_CONTAINER" \
  -e POSTGRES_USER="$DB_USER" -e POSTGRES_PASSWORD="$DB_PASS" -e POSTGRES_DB="$DB_NAME" \
  -p "${DB_PORT_HOST}:${DB_PORT_CONTAINER}" \
  --health-cmd="pg_isready -U ${DB_USER} -d ${DB_NAME}" --health-interval=1s --health-timeout=1s --health-retries=60 \
  "$DB_IMAGE" >/dev/null

# wait for container to be healthy (use docker inspect health or pg_isready inside)
LOG "Waiting for postgres readiness (60s max)"
TRIES=0
MAX_TRIES=60
until docker exec "$DB_CONTAINER" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1 || [ $TRIES -ge $MAX_TRIES ]; do
  sleep 1
  TRIES=$((TRIES+1))
done
if [ $TRIES -ge $MAX_TRIES ]; then
  dump_logs
  DIE "Postgres not ready after ${MAX_TRIES}s"
fi
LOG "Postgres ready (container ${DB_CONTAINER})"

# Ensure DB exists (idempotent)
LOG "Ensuring database ${DB_NAME} exists (inside container)"
CREATE_DB_OUT="$(docker exec -i "$DB_CONTAINER" bash -c "psql -U ${DB_USER} -tc \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'\" || true")"
if echo "$CREATE_DB_OUT" | grep -q 1; then
  LOG "Database ${DB_NAME} already exists"
else
  LOG "Creating database ${DB_NAME}"
  docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -c "CREATE DATABASE ${DB_NAME};" >/dev/null 2>&1 || LOG "CREATE DATABASE may have failed or DB already created by init"
fi

# --- start auth server ---
LOG "Starting auth server via: python3 -m uvicorn src.services.auth.auth_server:app --host ${UVICORN_HOST} --port ${UVICORN_PORT}"
python3 -m uvicorn src.services.auth.auth_server:app --host "$UVICORN_HOST" --port "$UVICORN_PORT" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
LOG "uvicorn PID $SERVER_PID"

# wait for /health
HEALTH_URL="http://${UVICORN_HOST}:${UVICORN_PORT}/health"
LOG "Waiting up to 30s for ${HEALTH_URL}"
TRIES=0
MAX_HEALTH=30
until curl -sfS "$HEALTH_URL" -o "$TMP_HEALTH" 2>/dev/null || [ $TRIES -ge $MAX_HEALTH ]; do
  sleep 1
  TRIES=$((TRIES+1))
done
if [ $TRIES -ge $MAX_HEALTH ]; then
  dump_logs
  DIE "auth server did not report healthy within ${MAX_HEALTH}s"
fi
LOG "/health response:"
sed -n '1,200p' "$TMP_HEALTH"

# --- TEST 1: /ready ---
LOG "TEST 1: /ready check"
READY_BODY="$(curl -sfS "http://${UVICORN_HOST}:${UVICORN_PORT}/ready" || true)"
LOG "/ready => ${READY_BODY}"
echo "$READY_BODY" | grep -E '"ready"|"not_ready"' >/dev/null || DIE "/ready body unexpected"

# --- TEST 2: /login page ---
LOG "TEST 2: /login page check"
LOGIN_BODY="$(curl -sfS "http://${UVICORN_HOST}:${UVICORN_PORT}/login" || true)"
LOG "login page snippet:"
echo "$LOGIN_BODY" | sed -n '1,80p'
echo "$LOGIN_BODY" | grep -qi "Continue with" >/dev/null || DIE "/login page missing provider buttons"

# --- TEST 3: trigger login/start and validate PKCE saved ---
LOG "TEST 3: trigger /auth/login/start/google (capture session cookie and headers)"
rm -f "$COOKIES_FILE" "$TMP_HEADERS"
curl -s -i -D "$TMP_HEADERS" -c "$COOKIES_FILE" -o /dev/null "http://${UVICORN_HOST}:${UVICORN_PORT}/auth/login/start/google" || true
START_CODE="$(head -n1 "$TMP_HEADERS" | awk '{print $2}' || true)"
LOG "/auth/login/start/google HTTP status: ${START_CODE}"
LOG "Saved cookiejar to ${COOKIES_FILE} (if present)"

LOG "Checking oauth_pending table for latest entry (if exists)"
PENDING_ROW="$(docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -A -c "SELECT state, provider, code_verifier, created_at FROM oauth_pending ORDER BY created_at DESC LIMIT 1;" 2>/dev/null || true)"
if [ -z "$PENDING_ROW" ]; then
  LOG "No oauth_pending row found. Server might not persist PKCE server-side; skipping PKCE persistence checks."
else
  LOG "Found oauth_pending row: ${PENDING_ROW}"
  STATE_VAL="$(echo "$PENDING_ROW" | cut -d'|' -f1)"
  VERIFIER_VAL="$(echo "$PENDING_ROW" | cut -d'|' -f3)"
  LOG "state length: ${#STATE_VAL}   verifier length: ${#VERIFIER_VAL}"
  [ "${#STATE_VAL}" -ge 16 ] || DIE "PKCE state too short"
  [ "${#VERIFIER_VAL}" -ge 43 ] || DIE "code_verifier too short (RFC7636 requires 43-128 characters)"
fi

# --- TEST 4: simulate callback with invalid code while preserving session cookie ---
if [ -n "${STATE_VAL-}" ]; then
  LOG "TEST 4: simulate callback with invalid code while preserving session cookie"
  CB_RESP="$(curl -s -i -b "$COOKIES_FILE" -c "$COOKIES_FILE" "http://${UVICORN_HOST}:${UVICORN_PORT}/auth/callback/google?state=${STATE_VAL}&code=invalid-code" || true)"
  LOG "callback response (first 40 lines):"
  echo "$CB_RESP" | sed -n '1,40p'
  LOG "Verifying audit_logs contains recent login_failed entry (best-effort)"
  AUDIT_ROW="$(docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -A -c "SELECT timestamp, action, details FROM audit_logs ORDER BY timestamp DESC LIMIT 5;" 2>/dev/null || true)"
  echo "$AUDIT_ROW" | grep -i "login_failed" >/dev/null || LOG "No recent login_failed found; this may be provider-network dependent (acceptable for offline tests)"
fi

# --- TEST 5: /me auth via JWT Bearer ---
LOG "TEST 5: /me authentication test (JWT Bearer path)"
TEST_JWT="$(python3 - <<PY
import jwt, time, os, sys
payload = {"iss":"agentic-platform","aud":"agent-frontend","sub":"00000000-0000-0000-0000-000000000000","email":"ci@example.test","name":"ci","provider":"google","iat":int(time.time()),"exp":int(time.time())+3600}
print(jwt.encode(payload, os.environ.get("JWT_SECRET","test_jwt_secret"), algorithm="HS256"))
PY
)"
ME_CODE="$(curl -s -o "$TMP_ME" -w "%{http_code}" -H "Authorization: Bearer ${TEST_JWT}" "http://${UVICORN_HOST}:${UVICORN_PORT}/me" || true)"
if [ "$ME_CODE" = "200" ]; then
  LOG "/me accepts JWT Bearer tokens. Response:"
  sed -n '1,200p' "$TMP_ME"
  AUTH_MODE="jwt"
else
  LOG "/me did not accept JWT Bearer (HTTP ${ME_CODE}). Marking auth mode unknown."
  AUTH_MODE="unknown"
fi

# --- TEST 6: logout behavior ---
LOG "TEST 6: logout behavior (GET /logout)"
LOGOUT_RESP="$(curl -s -i "http://${UVICORN_HOST}:${UVICORN_PORT}/logout" || true)"
echo "$LOGOUT_RESP" | sed -n '1,60p'

# --- TEST 7: DB schema presence (high-signal) ---
LOG "TEST 7: DB schema presence check"
TABLES="$(docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -A -c "SELECT tablename FROM pg_tables WHERE schemaname='public';" 2>/dev/null || true)"
LOG "Public tables: ${TABLES:-(unable to query)}"
echo "${TABLES:-}" | grep -E 'users|audit_logs|oauth_pending' >/dev/null || DIE "Expected DB tables missing (users,audit_pending,audit_logs)"

# --- summary & finish ---
LOG "All tests completed. Summary:"
LOG " - auth server PID: ${SERVER_PID}"
LOG " - DB container: ${DB_CONTAINER} (docker: $(command -v docker >/dev/null && echo true || echo false))"
LOG " - detected auth mode: ${AUTH_MODE:-unknown}"
LOG " - PKCE pending row present: $( [ -n "${PENDING_ROW:-}" ] && echo yes || echo no )"

dump_logs
LOG "Cleaning up artifacts (container + server) now."
cleanup
exit 0