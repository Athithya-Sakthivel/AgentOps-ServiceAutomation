# src/services/task_service/app.py
"""
Task service FastAPI app (production-ready, telemetry-aware).

- Endpoints:
  GET  /health
  GET  /ready
  POST /tasks    {"title": "..."}  (Authorization: Bearer <jwt>)
  GET  /tasks    (Authorization required)

- Uses shared telemetry/logging helpers from src.services.common
- Uses asyncpg pool for Postgres; optional Valkey client for caching
- Publishes activity events to ACTIVITY_SERVICE_URL (best-effort)
- Use absolute imports so uvicorn can start with:
    uvicorn src.services.task_service.app:app
"""
from __future__ import annotations

import json
import os
import time
import uuid
from contextlib import asynccontextmanager
from typing import Any, Dict, List, Optional

import httpx
import jwt
from jwt import ExpiredSignatureError, InvalidTokenError
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from starlette.middleware.base import BaseHTTPMiddleware

# defensive imports from shared package
try:
    from src.services.common.telemetry import init_telemetry, get_tracer, get_meter
except Exception:  # pragma: no cover - defensive fallback
    init_telemetry = lambda *a, **k: None  # type: ignore
    get_tracer = lambda *a, **k: None  # type: ignore
    get_meter = lambda *a, **k: None  # type: ignore

try:
    from src.services.common.logging import get_structured_logger
except Exception:  # pragma: no cover - fallback
    import logging

    def get_structured_logger(name: str):
        return logging.getLogger(name)

try:
    from src.services.common.metrics import ensure_common_instruments
except Exception:
    ensure_common_instruments = None  # type: ignore

# db helpers (absolute import)
from src.services.task_service import connections  # expected: init_db_pool, init_db_schema, init_valkey_client, mask_dsn

# -----------------------
# Configuration (env)
# -----------------------
SERVICE_NAME = os.getenv("SERVICE_NAME", "task")
SERVICE_VERSION = os.getenv("SERVICE_VERSION", "0.0.0")
DATABASE_URL = os.getenv("DATABASE_URL")
VALKEY_URL = os.getenv("VALKEY_URL", "")
ACTIVITY_SERVICE_URL = os.getenv("ACTIVITY_SERVICE_URL", "http://127.0.0.1:8002")
AUTH_SERVICE_URL = os.getenv("AUTH_SERVICE_URL", "")  # optional fallback to /me
JWT_SECRET = os.getenv("JWT_SECRET")
JWT_AUD = os.getenv("JWT_AUD", "agent-frontend")
JWT_ISS = os.getenv("JWT_ISS", "agentic-platform")

# fail fast if required env missing
_missing = [k for k, v in {"DATABASE_URL": DATABASE_URL, "JWT_SECRET": JWT_SECRET}.items() if not v]
if _missing:
    raise SystemExit(f"Missing required env vars for task service: {', '.join(_missing)}")

# telemetry & logger (init early)
init_telemetry(service_name=SERVICE_NAME, service_version=SERVICE_VERSION, otlp_insecure=True)
logger = get_structured_logger("task")
tracer = get_tracer("task")
meter = get_meter("task")

# instruments (defensive)
_tasks_created_counter = None
_tasks_list_counter = None
_tasks_errors_counter = None
_http_client_hist = None

if meter is not None:
    try:
        _tasks_created_counter = getattr(meter, "create_counter", meter.__dict__.get("create_counter", None))(
            "tasks.created_total", description="Total tasks created"
        )
    except Exception:
        _tasks_created_counter = None
    try:
        _tasks_list_counter = getattr(meter, "create_counter", lambda *a, **k: None)("tasks.list_total", description="Task list calls")
    except Exception:
        _tasks_list_counter = None
    try:
        _tasks_errors_counter = getattr(meter, "create_counter", lambda *a, **k: None)(
            "tasks.errors_total", description="Task errors"
        )
    except Exception:
        _tasks_errors_counter = None
    try:
        _http_client_hist = getattr(meter, "create_histogram", lambda *a, **k: None)(
            "http.client.requests_ms", description="Outgoing HTTP client latency (ms)"
        )
    except Exception:
        _http_client_hist = None

    if ensure_common_instruments:
        try:
            ensure_common_instruments(meter)
        except Exception:
            logger.exception("metrics.ensure_common_instruments.failed")

# -----------------------
# FastAPI + middleware
# -----------------------
app = FastAPI(title="task-service", version=SERVICE_VERSION)


class RequestIDMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        reqid = request.headers.get("X-Request-ID") or request.headers.get("x-request-id")
        if not reqid:
            reqid = str(uuid.uuid4())
        # attach safely to request.state (do not treat state as dict)
        try:
            setattr(request.state, "request_id", reqid)
        except Exception:
            # best-effort fallback
            request.scope.setdefault("state", {})["request_id"] = reqid
        response = await call_next(request)
        try:
            response.headers["X-Request-ID"] = reqid
        except Exception:
            pass
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
pg_pool = None  # type: ignore
valkey_client = None  # type: ignore

# -----------------------
# Auth helpers (local JWT verification + optional fallback to /me)
# -----------------------
def _extract_bearer(auth_header: Optional[str]) -> str:
    if not auth_header:
        raise HTTPException(status_code=401, detail="Missing Authorization header")
    if not auth_header.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Invalid Authorization header")
    return auth_header.split(" ", 1)[1].strip()


def _verify_jwt_local(token: str) -> Dict[str, Any]:
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=["HS256"], audience=JWT_AUD, issuer=JWT_ISS)
        return payload
    except ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token expired")
    except InvalidTokenError:
        raise HTTPException(status_code=401, detail="Invalid token")


async def _validate_request_and_get_user(request: Request) -> Dict[str, Any]:
    auth_header = request.headers.get("authorization")
    token = _extract_bearer(auth_header)
    # try local decode
    try:
        payload = _verify_jwt_local(token)
        logger.info(json.dumps({"event": "auth.verify.local", "sub": payload.get("sub")}))
        return payload
    except HTTPException as exc:
        # fallback to auth service /me if configured
        if AUTH_SERVICE_URL:
            logger.info(json.dumps({"event": "auth.verify.fallback_remote", "reason": exc.detail}))
            try:
                async with httpx.AsyncClient(timeout=3.0) as client:
                    resp = await client.get(f"{AUTH_SERVICE_URL}/me", headers={"Authorization": f"Bearer {token}"})
                if resp.status_code == 200:
                    data = resp.json()
                    user = data.get("user") or data
                    logger.info(json.dumps({"event": "auth.verify.remote.success", "sub": user.get("sub") if isinstance(user, dict) else None}))
                    return user
                raise HTTPException(status_code=401, detail="Invalid token")
            except httpx.HTTPError:
                logger.exception("auth.verify.remote.error")
                raise HTTPException(status_code=502, detail="auth_unreachable")
        else:
            raise

# -----------------------
# Lifespan (startup/shutdown)
# -----------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    global pg_pool, valkey_client
    try:
        logger.info(json.dumps({"event": "startup.init", "database_url": connections.mask_dsn(DATABASE_URL), "valkey_present": bool(VALKEY_URL)}))
    except Exception:
        logger.info("startup.init")

    # create DB pool (use helper from connections if present)
    pg_pool = await connections.init_db_pool(DATABASE_URL, min_size=1, max_size=10, command_timeout=5)
    logger.info(json.dumps({"event": "pg.pool.created", "min_size": 1, "max_size": 10}))

    # ensure table exists (idempotent)
    try:
        async with pg_pool.acquire() as conn:
            await conn.execute(
                """
                CREATE TABLE IF NOT EXISTS tasks (
                    id SERIAL PRIMARY KEY,
                    title TEXT NOT NULL,
                    created_by TEXT,
                    created_at TIMESTAMPTZ DEFAULT NOW()
                );
                """
            )
            logger.info(json.dumps({"event": "pg.migrate.complete", "table": "tasks"}))
    except Exception:
        logger.exception("pg.migrate.failed")
        raise

    # init valkey client if configured (best-effort)
    if VALKEY_URL:
        try:
            valkey_client = await connections.init_valkey_client(VALKEY_URL)
            logger.info(json.dumps({"event": "valkey.client.connected"}))
        except Exception:
            valkey_client = None
            logger.exception("valkey.client.connect.failed (continuing without valkey)")

    # register instruments if helper present
    try:
        if meter and ensure_common_instruments:
            ensure_common_instruments(meter)
    except Exception:
        logger.exception("metrics.ensure_failed")

    try:
        yield
    finally:
        logger.info(json.dumps({"event": "shutdown.start"}))
        if pg_pool:
            try:
                await pg_pool.close()
                logger.info(json.dumps({"event": "pg.pool.closed"}))
            except Exception:
                logger.exception("pg.pool.close.failed")
        if valkey_client:
            try:
                await valkey_client.close()
                logger.info(json.dumps({"event": "valkey.client.closed"}))
            except Exception:
                logger.exception("valkey.client.close.failed")
        logger.info(json.dumps({"event": "shutdown.complete"}))


app.router.lifespan_context = lifespan  # type: ignore

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
    reqid = getattr(request.state, "request_id", None)

    logger.info(json.dumps({"event": "task.create.start", "title": body.title, "user": sub, "reqid": reqid}))
    # insert into Postgres (core)
    try:
        async with pg_pool.acquire() as conn:
            row = await conn.fetchrow(
                "INSERT INTO tasks (title, created_by) VALUES ($1, $2) RETURNING id, title, created_at",
                body.title,
                sub,
            )
    except Exception:
        logger.exception("task.create.db_error")
        if _tasks_errors_counter:
            try:
                _tasks_errors_counter.add(1, {"phase": "db_insert"})
            except Exception:
                pass
        raise HTTPException(status_code=500, detail="db_error")

    task = {"id": int(row["id"]), "title": row["title"], "created_by": sub, "created_at": str(row["created_at"])}
    logger.info(json.dumps({"event": "task.created", "task_id": task["id"], "user": sub, "reqid": reqid}))

    # cache in valkey (best-effort) - try common API (.set / .expire)
    if valkey_client:
        try:
            payload_bytes = json.dumps(task).encode("utf-8")
            # prefer a helper on connections (if exists) to abstract client API
            if hasattr(connections, "cache_set_task"):
                try:
                    await connections.cache_set_task(valkey_client, task["id"], payload_bytes)
                except Exception:
                    # fallback to direct client call
                    if hasattr(valkey_client, "set"):
                        await valkey_client.set(f"task:{task['id']}", payload_bytes)
                        try:
                            if hasattr(valkey_client, "expire"):
                                await valkey_client.expire(f"task:{task['id']}", int(os.getenv("TASK_CACHE_TTL", "60")))
                        except Exception:
                            pass
            else:
                if hasattr(valkey_client, "set"):
                    await valkey_client.set(f"task:{task['id']}", payload_bytes)
                    try:
                        if hasattr(valkey_client, "expire"):
                            await valkey_client.expire(f"task:{task['id']}", int(os.getenv("TASK_CACHE_TTL", "60")))
                    except Exception:
                        pass
            logger.info(json.dumps({"event": "valkey.set", "key": f"task:{task['id']}", "ttl": int(os.getenv("TASK_CACHE_TTL", "60"))}))
        except Exception:
            logger.exception("valkey.set.failed")

    # publish activity event (best-effort)
    activity_payload = {"type": "task_created", "task_id": task["id"], "user": sub}
    try:
        start = time.time()
        async with httpx.AsyncClient(timeout=3.0) as client:
            resp = await client.post(f"{ACTIVITY_SERVICE_URL}/activity", json=activity_payload)
        if _http_client_hist:
            try:
                _http_client_hist.record(int((time.time() - start) * 1000), {"http.host": ACTIVITY_SERVICE_URL})
            except Exception:
                try:
                    _http_client_hist.record(int((time.time() - start) * 1000))
                except Exception:
                    pass
        logger.info(json.dumps({"event": "activity.emit", "status_code": resp.status_code, "task_id": task["id"]}))
    except Exception:
        logger.exception("activity.emit.failed")
    if _tasks_created_counter:
        try:
            _tasks_created_counter.add(1, {"service.name": SERVICE_NAME})
        except Exception:
            try:
                _tasks_created_counter.add(1)
            except Exception:
                pass

    return task


@app.get("/tasks")
async def list_tasks(request: Request):
    # auth
    _ = await _validate_request_and_get_user(request)
    # query rows
    try:
        async with pg_pool.acquire() as conn:
            rows = await conn.fetch("SELECT id, title, created_by, created_at FROM tasks ORDER BY id DESC LIMIT 100")
    except Exception:
        logger.exception("task.list.db_error")
        if _tasks_errors_counter:
            try:
                _tasks_errors_counter.add(1, {"phase": "list"})
            except Exception:
                pass
        raise HTTPException(status_code=500, detail="db_error")

    out: List[Dict[str, Any]] = [
        {"id": int(r["id"]), "title": r["title"], "created_by": r["created_by"], "created_at": str(r["created_at"])} for r in rows
    ]
    if _tasks_list_counter:
        try:
            _tasks_list_counter.add(len(out), {"service.name": SERVICE_NAME})
        except Exception:
            try:
                _tasks_list_counter.add(len(out))
            except Exception:
                pass
    logger.info(json.dumps({"event": "task.list.complete", "returned": len(out)}))
    return out