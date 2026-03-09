# src/services/task_service/connections.py
"""
Postgres pool and Valkey/Glide helpers for task service.

Exports:
- init_pg_pool(dsn, min_size=1, max_size=10, command_timeout=5)
- ensure_tasks_table(pool)
- mask_dsn(dsn)
- init_valkey_client(url)  # optional, raises if glide not installed
- valkey_set(client, key, bytes_payload, ttl=None)  # best-effort
"""

from __future__ import annotations

import asyncio
import os
from typing import Optional

import asyncpg

# Optional Glide/Valkey client
try:
    from glide import GlideClient, GlideClientConfiguration, NodeAddress, ServerCredentials  # type: ignore
except Exception:  # runtime-optional
    GlideClient = None  # type: ignore
    GlideClientConfiguration = None  # type: ignore
    NodeAddress = None  # type: ignore
    ServerCredentials = None  # type: ignore

STARTUP_RETRIES = int(os.getenv("STARTUP_RETRIES", "3"))
STARTUP_BASE_DELAY = float(os.getenv("STARTUP_BASE_DELAY", "0.5"))


async def init_pg_pool(dsn: str, min_size: int = 1, max_size: int = 10, command_timeout: int = 5) -> asyncpg.Pool:
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


async def ensure_tasks_table(pool: asyncpg.Pool) -> None:
    """Idempotently create tasks table used by the service."""
    async with pool.acquire() as conn:
        await conn.execute("SELECT pg_advisory_lock(1234567890)")
        try:
            await conn.execute("""
                CREATE TABLE IF NOT EXISTS tasks (
                    id SERIAL PRIMARY KEY,
                    title TEXT NOT NULL,
                    created_by TEXT,
                    created_at TIMESTAMPTZ DEFAULT NOW()
                );
            """)
        finally:
            await conn.execute("SELECT pg_advisory_unlock(1234567890)")


def _parse_valkey_url(url: str):
    """Parse redis-like url: redis://:password@host:port/db"""
    from urllib.parse import urlparse

    u = urlparse(url)
    return u.hostname or "localhost", u.port or 6379, u.password or ""


async def init_valkey_client(url: str):
    """Create Glide client. Raises meaningful error if Glide package missing."""
    if GlideClient is None:
        raise RuntimeError("Glide/Valkey client package not installed")
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


async def valkey_set(client, key: str, payload_bytes: bytes, ttl: Optional[int] = None) -> None:
    """
    Best-effort set into valkey/Glide.
    Handles multiple plausible client APIs and swallows errors.
    """
    if not client:
        return
    try:
        if hasattr(client, "set"):
            # common interface: await client.set(key, bytes)
            try:
                await client.set(key, payload_bytes)
            except TypeError:
                # maybe expects string
                await client.set(key, payload_bytes.decode("utf-8"))
        elif hasattr(client, "put"):
            await client.put(key, payload_bytes)
        elif hasattr(client, "execute"):
            # fallback to raw execution if provided
            try:
                await client.execute("SET", key, payload_bytes)
            except Exception:
                # some clients expect strings
                await client.execute("SET", key, payload_bytes.decode("utf-8"))
        # TTL handling if available
        if ttl is not None:
            try:
                if hasattr(client, "expire"):
                    await client.expire(key, ttl)
            except Exception:
                pass
    except Exception:
        # swallow errors - caching must not break main flow
        return


def mask_dsn(dsn: Optional[str]) -> str:
    """Mask DSN password for logs."""
    if not dsn:
        return ""
    try:
        if "@" in dsn and "://" in dsn:
            scheme, rest = dsn.split("://", 1)
            userinfo, host = rest.rsplit("@", 1)
            if ":" in userinfo:
                user, _pwd = userinfo.split(":", 1)
                return f"{scheme}://{user}:****@{host}"
    except Exception:
        pass
    return dsn