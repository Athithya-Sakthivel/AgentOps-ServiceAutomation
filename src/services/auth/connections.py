# src/services/auth/connections.py
"""
Database helpers for Auth service (asyncpg).
- init_db_pool(dsn)
- init_db_schema(pool)
- upsert_user, get_user_by_email
- oauth_pending storage helpers (save/pop)
- audit_auth_event
All functions are defensive and awaitable.
"""

from __future__ import annotations

import asyncio
import json
import os
from typing import Any

import asyncpg

STARTUP_RETRIES = int(os.getenv("STARTUP_RETRIES", "3"))
STARTUP_BASE_DELAY = float(os.getenv("STARTUP_BASE_DELAY", "0.5"))


async def init_db_pool(dsn: str, min_size: int = 1, max_size: int = 10, command_timeout: int = 5) -> asyncpg.Pool:
    """Create an asyncpg pool with retry/backoff. Raises last exception on failure."""
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
    """Ensure required tables/extensions exist (idempotent)."""
    async with pool.acquire() as conn:
        # advisory lock to avoid concurrent migrations
        await conn.execute("SELECT pg_advisory_lock(1234567890)")
        try:
            await conn.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto;")
            await conn.execute(
                """
                CREATE TABLE IF NOT EXISTS users (
                    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                    email TEXT NOT NULL UNIQUE,
                    provider TEXT NOT NULL,
                    name TEXT,
                    allowed_orgs TEXT[] DEFAULT ARRAY[]::TEXT[],
                    created_at TIMESTAMPTZ DEFAULT NOW(),
                    updated_at TIMESTAMPTZ DEFAULT NOW()
                );
                """
            )
            await conn.execute(
                """
                CREATE TABLE IF NOT EXISTS audit_logs (
                    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                    timestamp TIMESTAMPTZ DEFAULT NOW(),
                    user_id UUID,
                    action TEXT NOT NULL,
                    details JSONB NOT NULL,
                    ip_address INET
                );
                """
            )
            await conn.execute(
                """
                CREATE TABLE IF NOT EXISTS oauth_pending (
                    state TEXT PRIMARY KEY,
                    provider TEXT NOT NULL,
                    code_verifier TEXT NOT NULL,
                    redirect_uri TEXT NOT NULL,
                    created_at TIMESTAMPTZ DEFAULT NOW(),
                    ip_address INET
                );
                """
            )
        finally:
            await conn.execute("SELECT pg_advisory_unlock(1234567890)")


# application-facing DB helpers

async def upsert_user(pool: asyncpg.Pool, email: str, provider: str, name: str | None, allowed_orgs: list | None) -> str:
    """Upsert user by email; returns user id as string."""
    allowed_orgs = allowed_orgs or []
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            """
            INSERT INTO users (email, provider, name, allowed_orgs, updated_at)
            VALUES ($1, $2, $3, $4, NOW())
            ON CONFLICT (email) DO UPDATE
            SET provider = EXCLUDED.provider,
                name = EXCLUDED.name,
                allowed_orgs = EXCLUDED.allowed_orgs,
                updated_at = NOW()
            RETURNING id
            """,
            email.lower(),
            provider,
            name,
            allowed_orgs,
        )
        return str(row["id"])


async def get_user_by_email(pool: asyncpg.Pool, email: str) -> dict[str, Any] | None:
    """Return user row as dict or None."""
    async with pool.acquire() as conn:
        row = await conn.fetchrow("SELECT id, email, provider, name FROM users WHERE email = $1", email.lower())
        return dict(row) if row else None


async def save_oauth_pending(pool: asyncpg.Pool, state: str, provider: str, code_verifier: str, redirect_uri: str, ip_address: str | None) -> None:
    """Persist oauth pending state."""
    async with pool.acquire() as conn:
        await conn.execute(
            "INSERT INTO oauth_pending (state, provider, code_verifier, redirect_uri, ip_address) VALUES ($1,$2,$3,$4,$5) ON CONFLICT (state) DO UPDATE SET code_verifier = EXCLUDED.code_verifier, redirect_uri = EXCLUDED.redirect_uri, created_at = NOW(), ip_address = EXCLUDED.ip_address",
            state, provider, code_verifier, redirect_uri, ip_address
        )


async def pop_oauth_pending(pool: asyncpg.Pool, state: str) -> dict[str, Any] | None:
    """Fetch and delete oauth_pending row; returns dict or None."""
    async with pool.acquire() as conn:
        row = await conn.fetchrow("SELECT state, provider, code_verifier, redirect_uri, ip_address FROM oauth_pending WHERE state = $1", state)
        if not row:
            return None
        await conn.execute("DELETE FROM oauth_pending WHERE state = $1", state)
        return dict(row)


async def audit_auth_event(pool: asyncpg.Pool | None, user_id: str | None, action: str, details: dict[str, Any], ip_address: str | None = None) -> None:
    """Insert an audit log if pool available. Swallow exceptions (best-effort)."""
    if not pool:
        return
    try:
        async with pool.acquire() as conn:
            await conn.execute(
                "INSERT INTO audit_logs (user_id, action, details, ip_address) VALUES ($1, $2, $3, $4)",
                None if user_id in (None, "anonymous") else user_id,
                action,
                json.dumps(details),
                ip_address,
            )
    except Exception:
        # swallow to avoid breaking auth flow
        return


# utilities

def mask_dsn(dsn: str | None) -> str:
    """Mask password in a PostgreSQL DSN for safe logging."""
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
