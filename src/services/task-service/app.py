# src/services/task-service/app.py
"""
Production-ready Task service (FastAPI).
- Uses asyncpg create_pool / pool.close() (no unsupported kwargs).
- Optional Valkey (GLIDE) client for caching and activity publishing.
- Local JWT verification (PyJWT HS256) with optional fallback to auth /me.
- Request-ID middleware, structured JSON logs, startup/shutdown lifecycle with retries.
- Endpoints:
    GET  /health
    GET  /ready
    POST /tasks    {"title": "..."}  (requires Authorization: Bearer <jwt>)
    GET  /tasks    (requires Authorization)
Contracts and dependency usage follow the asyncpg and valkey-glide documented APIs.
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
import httpx
import jwt
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from jwt import ExpiredSignatureError, InvalidTokenError
from pydantic import BaseModel
from starlette.middleware.base import BaseHTTPMiddleware

# Glide (Valkey) is optional; guard its import
try:
    from glide import GlideClient, GlideClientConfiguration, NodeAddress, ServerCredentials
except Exception:
    GlideClient = None  # type: ignore
    GlideClientConfiguration = None  # type: ignore
    NodeAddress = None  # type: ignore
    ServerCredentials = None  # type: ignore

# -----------------------
# Configuration
# -----------------------
LOG_LEVEL = getattr(logging, os.getenv("LOG_LEVEL", "INFO").upper())
DATABASE_URL = os.getenv("DATABASE_URL")
VALKEY_URL = os.getenv("VALKEY_URL", "")  # optional: e.g. redis://:password@host:6379/0
AUTH_SERVICE_URL = os.getenv("AUTH_SERVICE_URL", "")  # optional fallback for /me verification
ACTIVITY_SERVICE_URL = os.getenv("ACTIVITY_SERVICE_URL", "http://127.0.0.1:8002")
JWT_SECRET = os.getenv("JWT_SECRET")

STARTUP_RETRIES = int(os.getenv("STARTUP_RETRIES", "3"))
STARTUP_BASE_DELAY = float(os.getenv("STARTUP_BASE_DELAY", "0.5"))

# DB pool sizing
PG_MIN_SIZE = int(os.getenv("PG_MIN_SIZE", "1"))
PG_MAX_SIZE = int(os.getenv("PG_MAX_SIZE", "10"))
PG_CMD_TIMEOUT = int(os.getenv("PG_CMD_TIMEOUT", "5"))

# cache TTL (seconds) for task cache
TASK_CACHE_TTL = int(os.getenv("TASK_CACHE_TTL", "60"))

# httpx timeouts
HTTP_TIMEOUT = float(os.getenv("HTTP_TIMEOUT", "3.0"))

# fail fast if required env missing
_required_missing = [k for k, v in {"DATABASE_URL": DATABASE_URL, "JWT_SECRET": JWT_SECRET}.items() if not v]
if _required_missing:
    raise SystemExit(f"Missing required env vars: {', '.join(_required_missing)}")

# -----------------------
# Logging (JSON-like)
# -----------------------
logging.basicConfig(level=LOG_LEVEL, format="%(message)s")
logger = logging.getLogger("task")

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
        # simple mask: replace password between : and @ if present
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
app = FastAPI(title="task-service", version="1.0.0")

class RequestIDMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        reqid = request.headers.get("X-Request-ID") or str(uuid.uuid4())
        request.state.request_id = reqid
        response = await call_next(request)
        response.headers["X-Request-ID"] = reqid
        return response

app.add_middleware(RequestIDMiddleware)

# -----------------------
# Models
# -----------------------
class TaskCreate(BaseModel):
    title: str

# -----------------------
# Globals for resources
# -----------------------
pg_pool: Optional[asyncpg.Pool] = None
valkey_client = None  # type: ignore

# -----------------------
# Helpers: asyncpg pool + valkey init (with retry/backoff)
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
    # support redis-like URL: redis://:pass@host:port/db
    from urllib.parse import urlparse
    u = urlparse(url)
    host = u.hostname or "localhost"
    port = u.port or 6379
    password = u.password or ""
    return host, port, password

async def _create_valkey_client(url: str):
    if not GlideClient:
        raise RuntimeError("valkey-glide not installed")
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
    _log("startup.init", {"database_url": mask_dsn(DATABASE_URL), "valkey_url_present": bool(VALKEY_URL)})
    # create pg pool
    pg_pool = await _create_pg_pool(DATABASE_URL)
    _log("pg.pool.created", {"min_size": PG_MIN_SIZE, "max_size": PG_MAX_SIZE})
    # ensure table exists (idempotent)
    try:
        async with pg_pool.acquire() as conn:
            await conn.execute("""
                CREATE TABLE IF NOT EXISTS tasks (
                    id SERIAL PRIMARY KEY,
                    title TEXT NOT NULL,
                    created_by TEXT,
                    created_at TIMESTAMPTZ DEFAULT NOW()
                );
            """)
            _log("pg.migrate.complete", {"table": "tasks"})
    except Exception as exc:
        _log("pg.migrate.failed", {"error": repr(exc)})
        raise

    # init valkey if configured
    if VALKEY_URL:
        try:
            valkey_client = await _create_valkey_client(VALKEY_URL)
            _log("valkey.client.connected", {})
        except Exception as exc:
            valkey_client = None
            _log("valkey.client.failed", {"error": repr(exc)})
            # proceed without valkey (best-effort caching)
    try:
        yield
    finally:
        _log("shutdown.start", {})
        if pg_pool:
            try:
                await pg_pool.close()
                _log("pg.pool.closed", {})
            except Exception as exc:
                _log("pg.pool.close.failed", {"error": repr(exc)})
        if valkey_client:
            try:
                await valkey_client.close()
                _log("valkey.client.closed", {})
            except Exception as exc:
                _log("valkey.client.close.failed", {"error": repr(exc)})
        _log("shutdown.complete", {})

app.router.lifespan_context = lifespan  # type: ignore

# -----------------------
# Auth helpers (local JWT verification + optional fallback to auth /me)
# -----------------------
def _extract_bearer(auth_header: Optional[str]) -> str:
    if not auth_header:
        raise HTTPException(status_code=401, detail="Missing Authorization header")
    if not auth_header.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Invalid Authorization header")
    return auth_header.split(" ", 1)[1].strip()

def _verify_jwt_local(token: str) -> Dict[str, Any]:
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=["HS256"], audience=os.getenv("JWT_AUD", "agent-frontend"), issuer=os.getenv("JWT_ISS", "agentic-platform"))
        return payload
    except ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token expired")
    except InvalidTokenError as e:
        raise HTTPException(status_code=401, detail="Invalid token")

async def _validate_request_and_get_user(request: Request) -> Dict[str, Any]:
    auth_header = request.headers.get("authorization")
    token = _extract_bearer(auth_header)
    # prefer local verification
    try:
        payload = _verify_jwt_local(token)
        _log("auth.verify.local", {"sub": payload.get("sub")})
        return payload
    except HTTPException as exc:
        # if AUTH_SERVICE_URL provided, attempt fallback verification via /me
        if AUTH_SERVICE_URL:
            _log("auth.verify.fallback_remote", {"reason": exc.detail})
            try:
                async with httpx.AsyncClient(timeout=HTTP_TIMEOUT) as client:
                    resp = await client.get(f"{AUTH_SERVICE_URL}/me", headers={"Authorization": f"Bearer {token}"})
                if resp.status_code == 200:
                    data = resp.json()
                    user = data.get("user")
                    if user:
                        _log("auth.verify.remote.success", {"sub": user.get("sub")})
                        return user
                raise HTTPException(status_code=401, detail="Invalid token")
            except httpx.HTTPError as e:
                _log("auth.verify.remote.error", {"error": repr(e)})
                raise HTTPException(status_code=502, detail="auth_unreachable")
        else:
            raise

# -----------------------
# Health/readiness endpoints
# -----------------------
@app.get("/health")
async def health():
    db_ok = bool(pg_pool)
    return JSONResponse({"status": "ok" if db_ok else "degraded"})

@app.get("/ready")
async def ready():
    if not pg_pool:
        return JSONResponse({"status": "not_ready", "reason": "db_unavailable"}, status_code=503)
    # valkey is optional; if configured, require it for ready
    if VALKEY_URL and not valkey_client:
        return JSONResponse({"status": "not_ready", "reason": "valkey_unavailable"}, status_code=503)
    return JSONResponse({"status": "ready"})

# -----------------------
# Task endpoints
# -----------------------
@app.post("/tasks")
async def create_task(request: Request, body: TaskCreate):
    # auth
    user = await _validate_request_and_get_user(request)
    sub = user.get("sub") or user.get("email") or "unknown"

    _log("task.create.start", {"title": body.title, "user": sub, "reqid": request.state.request_id})

    # insert into Postgres
    try:
        async with pg_pool.acquire() as conn:
            row = await conn.fetchrow(
                "INSERT INTO tasks (title, created_by) VALUES ($1, $2) RETURNING id, title, created_at",
                body.title,
                sub,
            )
    except Exception as exc:
        _log("task.create.db_error", {"error": repr(exc), "user": sub})
        raise HTTPException(status_code=500, detail="db_error")

    task = {"id": int(row["id"]), "title": row["title"], "created_by": sub, "created_at": str(row["created_at"])}
    _log("task.created", {"task_id": task["id"], "user": sub})

    # cache in valkey (best-effort)
    if valkey_client:
        try:
            try:
                # store as JSON bytes (GLIDE examples use bytes)
                payload_bytes = json.dumps(task).encode("utf-8")
                # set key
                await valkey_client.set(f"task:{task['id']}", payload_bytes)
                # set expiry if expire api exists; many GLIDE examples show expire usage - guard in try
                try:
                    await valkey_client.expire(f"task:{task['id']}", TASK_CACHE_TTL)
                except Exception:
                    # if expire not available, it's fine
                    pass
                _log("valkey.set", {"key": f"task:{task['id']}", "ttl": TASK_CACHE_TTL})
            except Exception as exc:
                _log("valkey.set.failed", {"error": repr(exc)})
        except Exception:
            # ensure cache failures do not block response
            _log("valkey.cache.exception", {})

    # publish activity event (best-effort)
    activity_payload = {"type": "task_created", "task_id": task["id"], "user": sub}
    try:
        async with httpx.AsyncClient(timeout=HTTP_TIMEOUT) as client:
            resp = await client.post(f"{ACTIVITY_SERVICE_URL}/activity", json=activity_payload)
            _log("activity.emit", {"status_code": resp.status_code, "task_id": task["id"]})
    except Exception as exc:
        _log("activity.emit.failed", {"error": repr(exc), "task_id": task["id"]})

    return task

@app.get("/tasks")
async def list_tasks(request: Request):
    _ = await _validate_request_and_get_user(request)
    try:
        async with pg_pool.acquire() as conn:
            rows = await conn.fetch("SELECT id, title, created_by, created_at FROM tasks ORDER BY id DESC LIMIT 100")
    except Exception as exc:
        _log("task.list.db_error", {"error": repr(exc)})
        raise HTTPException(status_code=500, detail="db_error")
    out: List[Dict[str, Any]] = [
        {"id": int(r["id"]), "title": r["title"], "created_by": r["created_by"], "created_at": str(r["created_at"])}
        for r in rows
    ]
    _log("task.list.complete", {"returned": len(out)})
    return out