# src/services/activity-service/app.py
"""
Production-ready Activity FastAPI service.
- Uses asyncpg create_pool / pool.close() (documented API).
- Optional Valkey (glide) client for event stream (GlideClient.create, lpush).
- Structured JSON-like logs, request-id middleware, startup/shutdown lifecycle with retries.
- Endpoints:
    GET  /health
    GET  /ready
    POST /activity        {"type":"task_created","task_id":123,"user":"ci-user", "metadata": {...}}
    GET  /activity/user/{user_id}
Contracts and dependency usage follow asyncpg and valkey-glide documented APIs.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import time
import uuid
from contextlib import asynccontextmanager
from typing import Any, Dict, List, Optional

import asyncpg
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from starlette.middleware.base import BaseHTTPMiddleware

# valkey-glide guarded import
try:
    from glide import GlideClient, GlideClientConfiguration, NodeAddress, ServerCredentials
except Exception:
    GlideClient = None  # type: ignore
    GlideClientConfiguration = None  # type: ignore
    NodeAddress = None  # type: ignore
    ServerCredentials = None  # type: ignore

# -----------------------
# Configuration (env)
# -----------------------
LOG_LEVEL = getattr(logging, os.getenv("LOG_LEVEL", "INFO").upper())
DATABASE_URL = os.getenv("DATABASE_URL")
VALKEY_URL = os.getenv("VALKEY_URL", "")  # optional, e.g. redis://:pass@host:6379/0

STARTUP_RETRIES = int(os.getenv("STARTUP_RETRIES", "3"))
STARTUP_BASE_DELAY = float(os.getenv("STARTUP_BASE_DELAY", "0.5"))

PG_MIN_SIZE = int(os.getenv("PG_MIN_SIZE", "1"))
PG_MAX_SIZE = int(os.getenv("PG_MAX_SIZE", "6"))
PG_CMD_TIMEOUT = int(os.getenv("PG_CMD_TIMEOUT", "5"))

# -----------------------
# Basic validation
# -----------------------
_missing = [k for k, v in {"DATABASE_URL": DATABASE_URL}.items() if not v]
if _missing:
    raise SystemExit(f"Missing required env var(s): {', '.join(_missing)}")

# -----------------------
# Logging (structured-ish)
# -----------------------
logging.basicConfig(level=LOG_LEVEL, format="%(message)s")
logger = logging.getLogger("activity")

def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

def _log(event: str, payload: Optional[Dict[str, Any]] = None) -> None:
    payload = payload or {}
    meta = {"event": event, "time": _now_iso(), **payload}
    logger.info(json.dumps(meta, default=str))

def mask_dsn(dsn: Optional[str]) -> str:
    if not dsn:
        return ""
    try:
        if "@" in dsn and "://" in dsn:
            scheme, rest = dsn.split("://", 1)
            userinfo, hostpart = rest.rsplit("@", 1)
            if ":" in userinfo:
                user, _ = userinfo.split(":", 1)
                return f"{scheme}://{user}:****@{hostpart}"
    except Exception:
        pass
    return dsn

# -----------------------
# FastAPI + middleware
# -----------------------
app = FastAPI(title="activity-service", version="1.0.0")

class RequestIDMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        reqid = request.headers.get("X-Request-ID") or str(uuid.uuid4())
        request.state.request_id = reqid
        _log("http.request.start", {"method": request.method, "path": request.url.path, "reqid": reqid, "client": request.client.host if request.client else None})
        try:
            resp = await call_next(request)
            status = resp.status_code
        except Exception as exc:
            _log("http.request.exception", {"error": repr(exc), "reqid": reqid})
            raise
        _log("http.request.complete", {"method": request.method, "path": request.url.path, "status": status, "reqid": reqid})
        resp.headers["X-Request-ID"] = reqid
        return resp

app.add_middleware(RequestIDMiddleware)

# -----------------------
# Models
# -----------------------
class ActivityEvent(BaseModel):
    type: str
    task_id: Optional[int] = None
    user: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = None

# -----------------------
# Globals
# -----------------------
pg_pool: Optional[asyncpg.Pool] = None
valkey_client = None  # type: ignore

# -----------------------
# Helpers: pg pool + valkey client init with retries
# -----------------------
async def _create_pg_pool(dsn: str) -> asyncpg.Pool:
    last_exc = None
    for attempt in range(1, STARTUP_RETRIES + 1):
        try:
            pool = await asyncpg.create_pool(dsn, min_size=PG_MIN_SIZE, max_size=PG_MAX_SIZE, command_timeout=PG_CMD_TIMEOUT)
            return pool
        except Exception as exc:
            last_exc = exc
            _log("pg.connect.retry", {"attempt": attempt, "error": repr(exc)})
            if attempt < STARTUP_RETRIES:
                await asyncio.sleep(STARTUP_BASE_DELAY * (2 ** (attempt - 1)))
    _log("pg.connect.failed", {"error": repr(last_exc)})
    raise last_exc

def _parse_valkey_url(url: str):
    from urllib.parse import urlparse
    u = urlparse(url)
    host = u.hostname or "localhost"
    port = u.port or 6379
    password = u.password or ""
    return host, port, password

async def _create_valkey_client(url: str):
    if not GlideClient:
        raise RuntimeError("valkey-glide not available in environment")
    host, port, password = _parse_valkey_url(url)
    addresses = [NodeAddress(host, port)]
    creds = ServerCredentials(password=password) if password else None
    config = GlideClientConfiguration(addresses=addresses, credentials=creds) if creds else GlideClientConfiguration(addresses=addresses)
    last_exc = None
    for attempt in range(1, STARTUP_RETRIES + 1):
        try:
            client = await GlideClient.create(config)
            return client
        except Exception as exc:
            last_exc = exc
            _log("valkey.connect.retry", {"attempt": attempt, "error": repr(exc)})
            if attempt < STARTUP_RETRIES:
                await asyncio.sleep(STARTUP_BASE_DELAY * (2 ** (attempt - 1)))
    _log("valkey.connect.failed", {"error": repr(last_exc)})
    raise last_exc

# -----------------------
# Lifespan (startup/shutdown)
# -----------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    global pg_pool, valkey_client
    _log("startup.init", {"database_url": mask_dsn(DATABASE_URL), "valkey_present": bool(VALKEY_URL)})
    pg_pool = await _create_pg_pool(DATABASE_URL)
    _log("pg.pool.created", {"min_size": PG_MIN_SIZE, "max_size": PG_MAX_SIZE})
    # ensure table
    try:
        async with pg_pool.acquire() as conn:
            await conn.execute("""
                CREATE TABLE IF NOT EXISTS activity_logs (
                    id SERIAL PRIMARY KEY,
                    type TEXT NOT NULL,
                    task_id INT,
                    user_id TEXT,
                    metadata JSONB,
                    created_at TIMESTAMPTZ DEFAULT NOW()
                );
            """)
            await conn.execute("CREATE INDEX IF NOT EXISTS idx_activity_user_created_at ON activity_logs(user_id, created_at DESC);")
            await conn.execute("CREATE INDEX IF NOT EXISTS idx_activity_task_id ON activity_logs(task_id);")
            _log("pg.migrate.complete", {"table": "activity_logs"})
    except Exception as exc:
        _log("pg.migrate.failed", {"error": repr(exc)})
        raise

    # valkey client optional
    if VALKEY_URL:
        try:
            valkey_client = await _create_valkey_client(VALKEY_URL)
            _log("valkey.client.connected", {"valkey_url": VALKEY_URL})
        except Exception as exc:
            valkey_client = None
            _log("valkey.client.connect_failed", {"error": repr(exc)})
            # proceed: valkey is best-effort for events

    try:
        yield
    finally:
        _log("shutdown.start", {})
        if pg_pool:
            try:
                await pg_pool.close()
                _log("pg.pool.closed", {})
            except Exception as exc:
                _log("pg.pool.close_failed", {"error": repr(exc)})
        if valkey_client:
            try:
                await valkey_client.close()
                _log("valkey.client.closed", {})
            except Exception as exc:
                _log("valkey.client.close_failed", {"error": repr(exc)})
        _log("shutdown.complete", {})

app.router.lifespan_context = lifespan  # type: ignore

# -----------------------
# Endpoints
# -----------------------
@app.get("/health")
async def health():
    db_ok = bool(pg_pool)
    return JSONResponse({"status": "ok" if db_ok else "degraded"})

@app.get("/ready")
async def ready():
    if not pg_pool:
        return JSONResponse({"status": "not_ready", "reason": "db_unavailable"}, status_code=503)
    # valkey is optional: if configured require it for ready check
    if VALKEY_URL and not valkey_client:
        return JSONResponse({"status": "not_ready", "reason": "valkey_unavailable"}, status_code=503)
    return JSONResponse({"status": "ready"})

@app.post("/activity")
async def record_event(evt: ActivityEvent, request: Request):
    reqid = getattr(request.state, "request_id", None)
    _log("activity.receive", {"type": evt.type, "task_id": evt.task_id, "user": evt.user, "reqid": reqid})
    # insert into Postgres
    try:
        async with pg_pool.acquire() as conn:
            await conn.execute(
                "INSERT INTO activity_logs (type, task_id, user_id, metadata) VALUES ($1, $2, $3, $4)",
                evt.type,
                evt.task_id,
                evt.user,
                json.dumps(evt.metadata) if evt.metadata is not None else None,
            )
            _log("activity.db.inserted", {"type": evt.type, "task_id": evt.task_id, "user": evt.user, "reqid": reqid})
    except Exception as exc:
        _log("activity.db.insert_failed", {"error": repr(exc), "reqid": reqid})
        raise HTTPException(status_code=500, detail="db_error")

    # push to valkey stream/list - best-effort
    if valkey_client:
        try:
            payload_bytes = json.dumps(evt.dict()).encode("utf-8")
            # lpush expects a list of elements (per glide examples)
            await valkey_client.lpush("activity_stream", [payload_bytes])
            _log("valkey.lpush", {"stream": "activity_stream", "size_bytes": len(payload_bytes), "reqid": reqid})
        except Exception as exc:
            _log("valkey.lpush_failed", {"error": repr(exc), "reqid": reqid})
    else:
        _log("valkey.unavailable", {"reason": "client_not_initialized", "reqid": reqid})

    return JSONResponse({"status": "recorded"})

@app.get("/activity/user/{user_id}")
async def get_by_user(user_id: str, request: Request):
    reqid = getattr(request.state, "request_id", None)
    _log("activity.query.user.start", {"user_id": user_id, "reqid": reqid})
    try:
        async with pg_pool.acquire() as conn:
            rows = await conn.fetch(
                "SELECT id, type, task_id, user_id, metadata, created_at FROM activity_logs WHERE user_id = $1 ORDER BY created_at DESC LIMIT 100",
                user_id,
            )
            _log("activity.query.user.complete", {"user_id": user_id, "found": len(rows), "reqid": reqid})
    except Exception as exc:
        _log("activity.query.user.failed", {"user_id": user_id, "error": repr(exc), "reqid": reqid})
        raise HTTPException(status_code=500, detail="db_error")

    result: List[Dict[str, Any]] = [
        {
            "id": int(r["id"]),
            "type": r["type"],
            "task_id": r["task_id"],
            "user_id": r["user_id"],
            "metadata": r["metadata"],
            "created_at": str(r["created_at"]),
        }
        for r in rows
    ]
    return result