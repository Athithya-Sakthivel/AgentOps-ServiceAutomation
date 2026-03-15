# src/services/activity_service/connections.py
"""
DB and Valkey (Glide) connection helpers for activity service.

Public functions:
- init_db_pool(dsn)
- init_db_schema(pool)
- insert_activity(pool, type, task_id, user_id, metadata)
- init_valkey_client(url) -> glide client (optional)
- lpush_activity_stream(client, stream, payload_bytes) -> best-effort
- mask_dsn(dsn)
"""

from __future__ import annotations

import asyncio
import json
import os
from typing import Any, Dict, Optional

import asyncpg

# Guard glide import; many environments may not have it installed
try:
    from glide import GlideClient, GlideClientConfiguration, NodeAddress, ServerCredentials  # type: ignore
except Exception:  # pragma: no cover - runtime optional
    GlideClient = None  # type: ignore
    GlideClientConfiguration = None  # type: ignore
    NodeAddress = None  # type: ignore
    ServerCredentials = None  # type: ignore

STARTUP_RETRIES = int(os.getenv("STARTUP_RETRIES", "3"))
STARTUP_BASE_DELAY = float(os.getenv("STARTUP_BASE_DELAY", "0.5"))


async def init_db_pool(dsn: str, min_size: int = 1, max_size: int = 6, command_timeout: int = 5) -> asyncpg.Pool:
    """Create asyncpg pool with retry/backoff pattern."""
    last_exc = None
    for attempt in range(1, STARTUP_RETRIES + 1):
        try:
            pool = await asyncpg.create_pool(dsn, min_size=min_size, max_size=max_size, command_timeout=command_timeout)
            return pool
        except Exception as exc:
            last_exc = exc
            if attempt < STARTUP_RETRIES:
                await asyncio.sleep(STARTUP_BASE_DELAY * (2 ** (attempt - 1)))
    raise last_exc


async def init_db_schema(pool: asyncpg.Pool) -> None:
    """Create activity_logs table and helper objects idempotently."""
    async with pool.acquire() as conn:
        await conn.execute("SELECT pg_advisory_lock(987654321)")
        try:
            await conn.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto;")
            await conn.execute(
                """
                CREATE TABLE IF NOT EXISTS activity_logs (
                    id SERIAL PRIMARY KEY,
                    type TEXT NOT NULL,
                    task_id INTEGER,
                    user_id TEXT,
                    metadata JSONB,
                    created_at TIMESTAMPTZ DEFAULT NOW()
                );
                """
            )
        finally:
            await conn.execute("SELECT pg_advisory_unlock(987654321)")


async def insert_activity(pool: asyncpg.Pool, type_: str, task_id: Optional[int], user_id: Optional[str], metadata: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """
    Insert activity row and return the inserted record dict.
    Raises exception on DB errors.
    """
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            "INSERT INTO activity_logs (type, task_id, user_id, metadata) VALUES ($1, $2, $3, $4) RETURNING id, type, task_id, user_id, metadata, created_at",
            type_,
            task_id,
            user_id,
            json.dumps(metadata) if metadata is not None else None,
        )
        return dict(row)


# -----------------------
# Valkey/Glide helpers
# -----------------------
def _parse_valkey_url(url: str):
    """Parse redis-like URL: redis://:password@host:port/db"""
    from urllib.parse import urlparse

    u = urlparse(url)
    return u.hostname or "localhost", u.port or 6379, u.password or ""


async def init_valkey_client(url: str):
    """Create a Glide client. Raises if Glide client package not available."""
    if GlideClient is None:
        raise RuntimeError("Glide client not installed in environment")
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
            if attempt < STARTUP_RETRIES:
                await asyncio.sleep(STARTUP_BASE_DELAY * (2 ** (attempt - 1)))
    raise last_exc


async def lpush_activity_stream(client, stream: str, payload_bytes: bytes) -> None:
    """
    Best-effort push of activity payload to valkey/GLIDE stream.
    Client API differs across versions — attempt common method names.
    Swallow exceptions so caller is not blocked by cache/queue failures.
    """
    if not client:
        return
    try:
        # try idiomatic lpush API
        if hasattr(client, "lpush"):
            await client.lpush(stream, payload_bytes)
            return
        # some glide clients expose list_push or push
        if hasattr(client, "push"):
            await client.push(stream, payload_bytes)
            return
        if hasattr(client, "list_push"):
            await client.list_push(stream, payload_bytes)
            return
        # best-effort: try to send via low-level send/execute if available
        if hasattr(client, "execute"):
            try:
                await client.execute("LPUSH", stream, payload_bytes)
                return
            except Exception:
                pass
    except Exception:
        # Do not propagate; activity should succeed even if queueing fails
        return


def mask_dsn(dsn: Optional[str]) -> str:
    if not dsn:
        return ""
    try:
        if "@" in dsn and "://" in dsn:
            scheme, rest = dsn.split("://", 1)
            userinfo, hostpart = rest.rsplit("@", 1)
            if ":" in userinfo:
                user, _pwd = userinfo.split(":", 1)
                return f"{scheme}://{user}:****@{hostpart}"
    except Exception:
        pass
    return dsn