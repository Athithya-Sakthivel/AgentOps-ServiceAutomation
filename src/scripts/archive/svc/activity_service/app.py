# src/services/activity_service/app.py
"""
Activity service FastAPI app (production-ready, telemetry-aware).
- Accepts activity events via POST /activity
- Persists to Postgres activity_logs and enqueues to Valkey (optional)
- Exposes GET /activity/user/{user_id} to list events for a user
- Uses shared telemetry/logging/metrics from src.services.common
- Uses absolute imports so uvicorn can start with: uvicorn src.services.activity_service.app:app
"""
from __future__ import annotations

import json
import logging
import os
import time
import uuid
from contextlib import asynccontextmanager
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from starlette.middleware.base import BaseHTTPMiddleware

# Try to import common helpers defensively so this module remains robust if a helper is missing.
try:
    # telemetry (traces/metrics)
    from src.services.common.telemetry import init_telemetry, get_tracer, get_meter
except Exception:  # pragma: no cover - defensive
    init_telemetry = lambda *a, **k: None  # type: ignore
    get_tracer = lambda *a, **k: None  # type: ignore
    get_meter = lambda *a, **k: None  # type: ignore

try:
    # structured logging helper
    from src.services.common.logging import get_structured_logger
except Exception:  # pragma: no cover - defensive
    def get_structured_logger(name: str):
        return logging.getLogger(name)

try:
    # common metric instruments helper (optional)
    from src.services.common.metrics import ensure_common_instruments
except Exception:  # pragma: no cover - defensive
    ensure_common_instruments = None  # type: ignore

# db + valkey helpers (absolute import)
from src.services.activity_service import connections  # expected helpers: init_db_pool, init_db_schema, insert_activity, init_valkey_client, lpush_activity_stream, mask_dsn

# -------------------------
# Configuration
# -------------------------
SERVICE_NAME = os.getenv("SERVICE_NAME", "activity")
SERVICE_VERSION = os.getenv("SERVICE_VERSION", "0.0.0")
DATABASE_URL = os.getenv("DATABASE_URL")
VALKEY_URL = os.getenv("VALKEY_URL", "")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")

STARTUP_RETRIES = int(os.getenv("STARTUP_RETRIES", "3"))
STARTUP_BASE_DELAY = float(os.getenv("STARTUP_BASE_DELAY", "0.5"))

# minimal checks
_missing = [k for k, v in {"DATABASE_URL": DATABASE_URL}.items() if not v]
if _missing:
    raise SystemExit(f"Missing env vars for activity service: {', '.join(_missing)}")

# -------------------------
# initialize telemetry + logger
# -------------------------
# safe to call early; module must remain resilient if OTLP/OTEL libs are not present
init_telemetry(service_name=SERVICE_NAME, service_version=SERVICE_VERSION, otlp_insecure=True)
logger = get_structured_logger("activity")
tracer = get_tracer("activity")
meter = get_meter("activity")

# create module-level instruments defensively (OTel SDKs differ between versions)
_activity_receive_counter = None
_activity_db_insert_counter = None
_activity_lpush_counter = None
_activity_errors_counter = None
_activity_processing_hist = None

if meter is not None:
    try:
        # API differences: try common method names; wrap in try/except.
        try:
            _activity_receive_counter = meter.create_counter("activity.receive_count", description="Count of received activity events")
        except Exception:
            _activity_receive_counter = getattr(meter, "create_counter", lambda *a, **k: None)("activity.receive_count")
        try:
            _activity_db_insert_counter = meter.create_counter("activity.db_insert_count", description="Count of DB inserts for activity")
        except Exception:
            _activity_db_insert_counter = None
        try:
            _activity_lpush_counter = meter.create_counter("activity.lpush_count", description="Count of activity pushes to valkey")
        except Exception:
            _activity_lpush_counter = None
        try:
            _activity_errors_counter = meter.create_counter("activity.errors_total", description="Count of activity errors")
        except Exception:
            _activity_errors_counter = None
        try:
            _activity_processing_hist = meter.create_histogram("activity.processing_ms", description="Processing time for activity (ms)")
        except Exception:
            _activity_processing_hist = None

        # register/common instruments if helper present
        if ensure_common_instruments:
            try:
                ensure_common_instruments(meter)
            except Exception:
                logger.exception("metrics.ensure_common_instruments.failed")
    except Exception:
        logger.exception("metrics.init.failed")

# -------------------------
# FastAPI app
# -------------------------
app = FastAPI(title="Activity Service", version=SERVICE_VERSION)


class RequestIDMiddleware(BaseHTTPMiddleware):
    """Attach/generate X-Request-ID on request.state and expose on response header."""

    async def dispatch(self, request: Request, call_next):
        # prefer incoming header, else generate
        reqid = request.headers.get("x-request-id") or request.headers.get("X-Request-ID")
        if not reqid:
            reqid = str(uuid.uuid4())
        # set as attribute on request.state (State has attribute semantics)
        try:
            setattr(request.state, "request_id", reqid)
        except Exception:
            # defensive fallback: attach to scope.state (object)
            st = request.scope.get("state")
            if st is None:
                class _StateObj:  # minimal object to hold attributes
                    pass
                st = _StateObj()
                request.scope["state"] = st
            setattr(st, "request_id", reqid)

        response = await call_next(request)
        try:
            response.headers["X-Request-ID"] = reqid
        except Exception:
            # ignore header set failures
            pass
        return response


app.add_middleware(RequestIDMiddleware)

# -------------------------
# Pydantic models
# -------------------------
class ActivityIn(BaseModel):
    type: str
    task_id: Optional[int] = None
    user: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = None


# -------------------------
# Globals set in lifespan
# -------------------------
db_pool = None  # type: ignore
valkey_client = None  # type: ignore


# -------------------------
# Lifespan
# -------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    global db_pool, valkey_client
    try:
        logger.info(json.dumps({"event": "startup.init", "database_url": connections.mask_dsn(DATABASE_URL), "valkey_present": bool(VALKEY_URL)}))
    except Exception:
        logger.info("startup.init")

    # init DB pool
    db_pool = await connections.init_db_pool(DATABASE_URL, min_size=1, max_size=6, command_timeout=5)
    logger.info(json.dumps({"event": "database.pool.created", "min_size": 1, "max_size": 6}))

    try:
        await connections.init_db_schema(db_pool)
        logger.info(json.dumps({"event": "database.migrate.complete", "table": "activity_logs"}))
    except Exception:
        logger.exception("database.migrate.failed")
        raise

    # init valkey client if configured (best-effort)
    if VALKEY_URL:
        try:
            valkey_client = await connections.init_valkey_client(VALKEY_URL)
            logger.info(json.dumps({"event": "valkey.client.connected"}))
        except Exception:
            valkey_client = None
            logger.exception("valkey.client.connect.failed (continuing without valkey)")

    # ensure metrics instruments (register any additional)
    try:
        if meter and ensure_common_instruments:
            ensure_common_instruments(meter)
    except Exception:
        logger.exception("metrics.ensure_failed")

    try:
        yield
    finally:
        logger.info(json.dumps({"event": "shutdown.start"}))
        if db_pool:
            try:
                await db_pool.close()
                logger.info(json.dumps({"event": "database.pool.closed"}))
            except Exception:
                logger.exception("database.pool.close.failed")
        if valkey_client:
            try:
                # valkey client expected to implement .close()
                await valkey_client.close()
                logger.info(json.dumps({"event": "valkey.client.closed"}))
            except Exception:
                logger.exception("valkey.client.close.failed")
        logger.info(json.dumps({"event": "shutdown.complete"}))


app.router.lifespan_context = lifespan  # type: ignore

# -------------------------
# Endpoints
# -------------------------
@app.get("/health")
async def health():
    ok = bool(db_pool)
    return JSONResponse({"status": "ok" if ok else "degraded", "database": "connected" if ok else "unavailable"})


@app.post("/activity")
async def emit_activity(request: Request, payload: ActivityIn):
    """
    Persist activity and optionally push to valkey stream.
    Guarantees:
      - sets and reads request.state.request_id (no dict usage)
      - DB insert is the core operation; valkey push is best-effort
      - metrics/errors are recorded defensively
    """
    start_ts = time.time()
    reqid = getattr(request.state, "request_id", None)

    # metrics: receive
    try:
        if _activity_receive_counter:
            try:
                _activity_receive_counter.add(1, {"type": payload.type, "service.name": SERVICE_NAME})
            except Exception:
                # some meter implementations accept different arguments
                _activity_receive_counter.add(1)
    except Exception:
        logger.debug("metric.activity.receive.failed", extra={"reqid": reqid})

    # persist to DB (core)
    try:
        row = await connections.insert_activity(db_pool, payload.type, payload.task_id, payload.user, payload.metadata)
        if _activity_db_insert_counter:
            try:
                _activity_db_insert_counter.add(1, {"service.name": SERVICE_NAME, "type": payload.type})
            except Exception:
                _activity_db_insert_counter.add(1)
    except Exception:
        logger.exception("activity.db.insert.failed", extra={"reqid": reqid})
        if _activity_errors_counter:
            try:
                _activity_errors_counter.add(1, {"phase": "db_insert"})
            except Exception:
                pass
        raise HTTPException(status_code=500, detail="db_error")

    # push to valkey stream (best-effort)
    try:
        body = {
            "id": int(row["id"]),
            "type": row["type"],
            "task_id": row.get("task_id"),
            "user": row.get("user_id"),
            "created_at": str(row["created_at"]),
            "metadata": payload.metadata,
        }
        payload_bytes = json.dumps(body).encode("utf-8")
        # connections.lpush_activity_stream should be resilient; it may accept (client, key, bytes)
        await connections.lpush_activity_stream(valkey_client, "activity_stream", payload_bytes)
        if _activity_lpush_counter:
            try:
                _activity_lpush_counter.add(1, {"service.name": SERVICE_NAME})
            except Exception:
                _activity_lpush_counter.add(1)
    except Exception:
        # swallow queue push errors; keep request successful
        logger.exception("activity.queue.push.failed", extra={"reqid": reqid})
        if _activity_errors_counter:
            try:
                _activity_errors_counter.add(1, {"phase": "val_push"})
            except Exception:
                pass

    # record processing time
    duration_ms = int((time.time() - start_ts) * 1000)
    try:
        if _activity_processing_hist:
            try:
                _activity_processing_hist.record(duration_ms, {"service.name": SERVICE_NAME})
            except Exception:
                # some meter implementations may use .record(value)
                try:
                    _activity_processing_hist.record(duration_ms)
                except Exception:
                    pass
    except Exception:
        logger.debug("metric.activity.processing.failed", extra={"reqid": reqid})

    logger.info(json.dumps({"event": "activity.receive", "type": payload.type, "task_id": payload.task_id, "user": payload.user, "reqid": reqid, "activity_id": int(row["id"])}))
    return {
        "id": int(row["id"]),
        "type": row["type"],
        "task_id": row.get("task_id"),
        "user": row.get("user_id"),
        "created_at": str(row["created_at"]),
    }


@app.get("/activity/user/{user_id}")
async def list_activity_for_user(user_id: str, limit: int = 50):
    """
    Return recent activity rows for a user. Uses a defensive DB access pattern so behavior is predictable
    regardless of connection pool implementation.
    """
    try:
        # prefer a helper on connections (if present) to avoid SQL duplication
        if hasattr(connections, "fetch_activity_for_user"):
            rows = await connections.fetch_activity_for_user(db_pool, user_id, limit)
        else:
            # fallback: use pool acquire/fetch (asyncpg-style)
            async with db_pool.acquire() as conn:
                rows = await conn.fetch(
                    "SELECT id, type, task_id, user_id, metadata, created_at FROM activity_logs WHERE user_id = $1 ORDER BY id DESC LIMIT $2",
                    user_id,
                    limit,
                )
    except Exception:
        logger.exception("activity.query.failed", extra={"user_id": user_id})
        raise HTTPException(status_code=500, detail="db_error")

    out: List[Dict[str, Any]] = []
    for r in rows:
        try:
            out.append(
                {
                    "id": int(r["id"]),
                    "type": r["type"],
                    "task_id": r["task_id"],
                    "user_id": r["user_id"],
                    "metadata": r["metadata"],
                    "created_at": str(r["created_at"]),
                }
            )
        except Exception:
            # ignore bad row but log
            logger.exception("activity.query.row_decode_failed", extra={"row": r})

    logger.info(json.dumps({"event": "activity.query.user.complete", "user_id": user_id, "found": len(out)}))
    return out