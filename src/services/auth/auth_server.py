# src/services/auth/auth_server.py
"""
Production-ready Auth FastAPI service (OAuth + JWT issuance + /me verification).
- Uses asyncpg create_pool / pool.close() (no unsupported kwargs).
- Optional Valkey (GLIDE) client if AUTH_USE_VALKEY=true for sessions/rate-limits.
- Request-ID middleware, structured JSON logs, readiness endpoint.
- JWT creation/verification (HS256 via PyJWT). Requires JWT_SECRET and SESSION_SECRET.
- DB schema creation for users, oauth_pending, audit_logs (idempotent).
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import html
import json
import logging
import os
import secrets
import sys
import time
import uuid
from contextlib import asynccontextmanager
from typing import AsyncGenerator, Dict, Optional

import asyncpg
import jwt
from authlib.integrations.base_client.errors import MismatchingStateError, OAuthError
from authlib.integrations.starlette_client import OAuth
from authlib.jose.errors import JoseError
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from jwt import ExpiredSignatureError, InvalidTokenError
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.util import get_remote_address
from starlette.middleware.sessions import SessionMiddleware
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.types import ASGIApp, Receive, Scope, Send

# Optional Valkey client (glide)
try:
    from glide import GlideClient, GlideClientConfiguration, NodeAddress, ServerCredentials
except Exception:
    GlideClient = None  # type: ignore
    GlideClientConfiguration = None  # type: ignore
    NodeAddress = None  # type: ignore
    ServerCredentials = None  # type: ignore

# -------------------------
# Configuration (env)
# -------------------------
LOG_LEVEL = getattr(logging, os.getenv("LOG_LEVEL", "INFO").upper())
DATABASE_URL = os.getenv("DATABASE_URL")
JWT_SECRET = os.getenv("JWT_SECRET")
JWT_SECRET_PREVIOUS = os.getenv("JWT_SECRET_PREVIOUS", "")
SESSION_SECRET = os.getenv("SESSION_SECRET")
AUTH_BASE_URL = os.getenv("AUTH_BASE_URL", "")  # optional base used in redirect construction
JWT_EXP_SECONDS = int(os.getenv("JWT_EXP_SECONDS", "1800"))
JWT_ISS = os.getenv("JWT_ISS", "agentic-platform")
JWT_AUD = os.getenv("JWT_AUD", "agent-frontend")

# OAuth provider envs (optional)
GOOGLE_CLIENT_ID = os.getenv("GOOGLE_CLIENT_ID")
GOOGLE_CLIENT_SECRET = os.getenv("GOOGLE_CLIENT_SECRET")
MICROSOFT_CLIENT_ID = os.getenv("MICROSOFT_CLIENT_ID")
MICROSOFT_CLIENT_SECRET = os.getenv("MICROSOFT_CLIENT_SECRET")
MICROSOFT_TENANT_ID = os.getenv("MICROSOFT_TENANT_ID", "common")

# Valkey config toggle
AUTH_USE_VALKEY = os.getenv("AUTH_USE_VALKEY", "false").lower() == "true"
VALKEY_URL = os.getenv("VALKEY_URL", "")  # e.g. redis://:password@host:6379/0

# PKCE / oauth pending TTL etc
PKCE_TTL_SECONDS = int(os.getenv("PKCE_TTL_SECONDS", "300"))

# Startup retry/backoff
STARTUP_RETRIES = int(os.getenv("STARTUP_RETRIES", "3"))
STARTUP_BASE_DELAY = float(os.getenv("STARTUP_BASE_DELAY", "0.5"))

# minimal env checks (fail fast)
REQUIRED = {
    "DATABASE_URL": DATABASE_URL,
    "JWT_SECRET": JWT_SECRET,
    "SESSION_SECRET": SESSION_SECRET,
}
missing = [k for k, v in REQUIRED.items() if not v]
if missing:
    sys.stderr.write(f"ERROR: missing required env vars: {', '.join(missing)}\n")
    sys.exit(1)

# -------------------------
# Logging - structured JSON-like messages
# -------------------------
logging.basicConfig(level=LOG_LEVEL, format="%(message)s")
logger = logging.getLogger("auth")

def _log(event: str, payload: Optional[Dict] = None) -> None:
    payload = payload or {}
    meta = {
        "event": event,
        "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        **payload,
    }
    logger.info(json.dumps(meta, default=str))

def mask_dsn(dsn: Optional[str]) -> str:
    if not dsn:
        return ""
    # Mask password in a typical postgresql DSN
    try:
        if "@" in dsn and "://" in dsn:
            prefix, rest = dsn.split("@", 1)
            if ":" in prefix:
                scheme_user, pwd = prefix.split(":", 1)
                pwd_masked = "****"
                return f"{scheme_user.split('://',1)[0]}://{scheme_user.split('://',1)[1].split(':',1)[0]}:{pwd_masked}@{rest}"
    except Exception:
        pass
    return dsn

# -------------------------
# Request ID middleware
# -------------------------
class RequestIDMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        reqid = request.headers.get("X-Request-ID") or str(uuid.uuid4())
        request.state.request_id = reqid
        resp = await call_next(request)
        resp.headers["X-Request-ID"] = reqid
        return resp

# -------------------------
# FastAPI app & rate limiter
# -------------------------
app = FastAPI(title="Auth Service", version="1.0.0")
app.add_middleware(SessionMiddleware, secret_key=SESSION_SECRET, session_cookie="auth_session")
app.add_middleware(RequestIDMiddleware)
app.state.limiter = Limiter(key_func=get_remote_address)
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# OAuth registration
oauth = OAuth()
enabled_providers: list[str] = []

if GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET:
    oauth.register(
        name="google",
        client_id=GOOGLE_CLIENT_ID,
        client_secret=GOOGLE_CLIENT_SECRET,
        server_metadata_url="https://accounts.google.com/.well-known/openid-configuration",
        client_kwargs={"scope": "openid email profile", "prompt": "select_account"},
    )
    enabled_providers.append("google")
    _log("oauth.provider.registered", {"provider": "google"})

if MICROSOFT_CLIENT_ID and MICROSOFT_CLIENT_SECRET:
    oauth.register(
        name="microsoft",
        client_id=MICROSOFT_CLIENT_ID,
        client_secret=MICROSOFT_CLIENT_SECRET,
        server_metadata_url=f"https://login.microsoftonline.com/{MICROSOFT_TENANT_ID}/v2.0/.well-known/openid-configuration",
        client_kwargs={"scope": "openid email profile User.Read"},
    )
    enabled_providers.append("microsoft")
    _log("oauth.provider.registered", {"provider": "microsoft", "tenant": MICROSOFT_TENANT_ID})

if not enabled_providers:
    _log("no_oauth_providers_configured", {})

# -------------------------
# Globals for resources
# -------------------------
db_pool: Optional[asyncpg.Pool] = None
valkey_client = None  # type: ignore

# -------------------------
# Utility helpers
# -------------------------
def make_state() -> str:
    return secrets.token_urlsafe(32)

def make_code_verifier() -> str:
    return secrets.token_urlsafe(64)

def code_challenge_from_verifier(verifier: str) -> str:
    sha = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(sha).rstrip(b"=").decode("ascii")

def create_jwt(user_id: str, email: str, name: Optional[str], provider: str) -> str:
    iat = int(time.time())
    payload = {
        "iss": JWT_ISS,
        "aud": JWT_AUD,
        "sub": user_id,
        "email": email,
        "name": name or email.split("@")[0],
        "provider": provider,
        "iat": iat,
        "exp": iat + JWT_EXP_SECONDS,
    }
    return jwt.encode(payload, JWT_SECRET, algorithm="HS256")

def verify_jwt(token: str) -> Dict:
    # try current and previous secret (support key rotation)
    for secret in (JWT_SECRET, JWT_SECRET_PREVIOUS):
        if not secret:
            continue
        try:
            return jwt.decode(token, secret, algorithms=["HS256"], audience=JWT_AUD, issuer=JWT_ISS)
        except ExpiredSignatureError:
            raise
        except InvalidTokenError:
            continue
    raise InvalidTokenError("No valid secret found")

# -------------------------
# DB helpers (create tables, upsert user, oauth_pending storage)
# -------------------------
async def init_db_pool(dsn: str) -> asyncpg.Pool:
    """Create asyncpg pool with small retry/backoff pattern."""
    last_exc = None
    for attempt in range(1, STARTUP_RETRIES + 1):
        try:
            pool = await asyncpg.create_pool(dsn, min_size=1, max_size=10, command_timeout=5)
            return pool
        except Exception as exc:
            last_exc = exc
            _log("db.connect.retry", {"attempt": attempt, "error": repr(exc)})
            if attempt < STARTUP_RETRIES:
                await asyncio.sleep(STARTUP_BASE_DELAY * (2 ** (attempt - 1)))
    _log("db.connect.failed", {"error": repr(last_exc)})
    raise last_exc

async def init_db_schema(pool: asyncpg.Pool) -> None:
    async with pool.acquire() as conn:
        # advisory lock to avoid race on concurrent startups
        await conn.execute("SELECT pg_advisory_lock(1234567890)")
        await conn.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto;")
        await conn.execute("""
            CREATE TABLE IF NOT EXISTS users (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                email TEXT NOT NULL UNIQUE,
                provider TEXT NOT NULL,
                name TEXT,
                allowed_orgs TEXT[] DEFAULT ARRAY[]::TEXT[],
                created_at TIMESTAMPTZ DEFAULT NOW(),
                updated_at TIMESTAMPTZ DEFAULT NOW()
            );
        """)
        await conn.execute("""
            CREATE TABLE IF NOT EXISTS audit_logs (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                timestamp TIMESTAMPTZ DEFAULT NOW(),
                user_id UUID,
                action TEXT NOT NULL,
                details JSONB NOT NULL,
                ip_address INET
            );
        """)
        await conn.execute("""
            CREATE TABLE IF NOT EXISTS oauth_pending (
                state TEXT PRIMARY KEY,
                provider TEXT NOT NULL,
                code_verifier TEXT NOT NULL,
                redirect_uri TEXT NOT NULL,
                created_at TIMESTAMPTZ DEFAULT NOW(),
                ip_address INET
            );
        """)
        await conn.execute("SELECT pg_advisory_unlock(1234567890)")

async def audit_auth_event(user_id: Optional[str], action: str, details: Dict, ip_address: Optional[str] = None) -> None:
    if not db_pool:
        return
    try:
        async with db_pool.acquire() as conn:
            await conn.execute(
                "INSERT INTO audit_logs (user_id, action, details, ip_address) VALUES ($1, $2, $3, $4)",
                None if user_id is None or user_id == "anonymous" else user_id,
                action,
                json.dumps(details),
                ip_address,
            )
    except Exception as exc:
        _log("audit.log.failed", {"error": repr(exc)})

async def save_oauth_pending(state: str, provider: str, code_verifier: str, redirect_uri: str, ip_address: Optional[str]) -> None:
    if not db_pool:
        raise RuntimeError("DB not initialized")
    async with db_pool.acquire() as conn:
        await conn.execute(
            "INSERT INTO oauth_pending (state, provider, code_verifier, redirect_uri, ip_address) VALUES ($1,$2,$3,$4,$5) ON CONFLICT (state) DO UPDATE SET code_verifier = EXCLUDED.code_verifier, redirect_uri = EXCLUDED.redirect_uri, created_at = NOW(), ip_address = EXCLUDED.ip_address",
            state, provider, code_verifier, redirect_uri, ip_address,
        )

async def pop_oauth_pending(state: str) -> Optional[Dict]:
    if not db_pool:
        return None
    async with db_pool.acquire() as conn:
        row = await conn.fetchrow("SELECT state, provider, code_verifier, redirect_uri, ip_address FROM oauth_pending WHERE state = $1", state)
        if not row:
            return None
        await conn.execute("DELETE FROM oauth_pending WHERE state = $1", state)
        return dict(row)

async def get_user_by_email(email: str) -> Optional[Dict]:
    if not db_pool:
        return None
    async with db_pool.acquire() as conn:
        row = await conn.fetchrow("SELECT id, email, provider, name FROM users WHERE email = $1", email.lower())
        return dict(row) if row else None

async def upsert_user(email: str, provider: str, name: Optional[str], allowed_orgs: list) -> str:
    if not db_pool:
        raise RuntimeError("DB not initialized")
    email_lower = email.lower()
    async with db_pool.acquire() as conn:
        row = await conn.fetchrow("""
            INSERT INTO users (email, provider, name, allowed_orgs, updated_at)
            VALUES ($1, $2, $3, $4, NOW())
            ON CONFLICT (email) DO UPDATE
            SET provider = EXCLUDED.provider,
                name = EXCLUDED.name,
                allowed_orgs = EXCLUDED.allowed_orgs,
                updated_at = NOW()
            RETURNING id
            """, email_lower, provider, name, allowed_orgs)
        return str(row["id"])

# -------------------------
# Valkey/Glide helpers
# -------------------------
def _parse_valkey_url(url: str):
    # support redis-like url: redis://:password@host:port/db
    try:
        from urllib.parse import urlparse
        u = urlparse(url)
        return u.hostname or "localhost", u.port or 6379, u.password or ""
    except Exception:
        return "localhost", 6379, ""

async def init_valkey_client(url: str):
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

# -------------------------
# Lifespan - create resources on startup, cleanup on shutdown
# -------------------------
@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    global db_pool, valkey_client
    # DB pool
    _log("startup.init", {"database_url": mask_dsn(DATABASE_URL), "auth_use_valkey": AUTH_USE_VALKEY})
    db_pool = await init_db_pool(DATABASE_URL)
    _log("database.pool.created", {"min_size": 1, "max_size": 10})
    # Ensure schema
    try:
        await init_db_schema(db_pool)
        _log("database.migrate.complete", {})
    except Exception as exc:
        _log("database.migrate.failed", {"error": repr(exc)})
        # fail fast
        raise

    # Valkey (optional)
    if AUTH_USE_VALKEY:
        if not VALKEY_URL:
            _log("valkey.config.missing", {})
            raise RuntimeError("AUTH_USE_VALKEY=true but VALKEY_URL not provided")
        try:
            valkey_client = await init_valkey_client(VALKEY_URL)
            _log("valkey.client.connected", {"valkey_url": VALKEY_URL})
        except Exception:
            valkey_client = None
            _log("valkey.client.connect.failed", {})

    # yield control to app run
    try:
        yield
    finally:
        _log("shutdown.start", {})
        # close db pool
        if db_pool:
            try:
                await db_pool.close()
                _log("database.pool.closed", {})
            except Exception as exc:
                _log("database.pool.close.failed", {"error": repr(exc)})
        # close valkey client
        if valkey_client:
            try:
                await valkey_client.close()
                _log("valkey.client.closed", {})
            except Exception as exc:
                _log("valkey.client.close.failed", {"error": repr(exc)})
        _log("shutdown.complete", {})

app.router.lifespan_context = lifespan  # type: ignore

# -------------------------
# Endpoints
# -------------------------
@app.get("/health")
async def health():
    db_ok = bool(db_pool)
    providers = enabled_providers
    return JSONResponse({"status": "ok" if db_ok else "degraded", "database": "connected" if db_ok else "unavailable", "providers": providers})

@app.get("/ready")
async def ready():
    # ready only when DB is present and at least one provider configured
    if not db_pool:
        return JSONResponse({"status": "not_ready", "reason": "db_unavailable"}, status_code=503)
    if not enabled_providers:
        return JSONResponse({"status": "not_ready", "reason": "no_providers"}, status_code=503)
    return JSONResponse({"status": "ready"})

@app.get("/login", response_class=HTMLResponse)
async def login_page():
    if not enabled_providers:
        return HTMLResponse("<!doctype html><html><body><h2>No auth providers configured</h2></body></html>", status_code=503)
    # simple provider buttons (same UI used previously)
    buttons = []
    for provider in enabled_providers:
        btn = f'<a href="/auth/login/start/{provider}">Continue with {provider.capitalize()}</a>'
        buttons.append(btn)
    content = "<!doctype html><html><body>" + "".join(buttons) + "</body></html>"
    return HTMLResponse(content)

@app.get("/auth/login/start/{provider}")
async def login_start(request: Request, provider: str) -> Response:
    provider = provider.lower()
    if provider not in enabled_providers:
        _log("login.start.invalid_provider", {"provider": provider})
        raise HTTPException(status_code=400, detail="Provider not enabled")
    client = oauth.create_client(provider)
    base = AUTH_BASE_URL or f"{request.url.scheme}://{request.url.netloc}"
    redirect_uri = f"{base}/auth/callback/{provider}"
    client_ip = request.client.host if request.client else "unknown"
    state = make_state()
    code_verifier = make_code_verifier()
    code_challenge = code_challenge_from_verifier(code_verifier)
    try:
        await save_oauth_pending(state=state, provider=provider, code_verifier=code_verifier, redirect_uri=redirect_uri, ip_address=client_ip)
    except Exception as exc:
        _log("save_oauth_pending.failed", {"error": repr(exc)})
        raise HTTPException(status_code=500, detail="internal_error")
    _log("login.start.initiated", {"provider": provider, "redirect_uri": redirect_uri})
    try:
        return await client.authorize_redirect(request, redirect_uri, state=state, code_challenge=code_challenge, code_challenge_method="S256")
    except Exception as exc:
        try:
            await pop_oauth_pending(state)
        except Exception:
            _log("cleanup.pop_oauth_pending.failed", {})
        _log("login.start.provider_error", {"error": repr(exc)})
        raise HTTPException(status_code=502, detail="provider_error")

@app.get("/auth/callback/{provider}")
async def callback(request: Request, provider: str) -> Response:
    provider = provider.lower()
    if provider not in enabled_providers:
        _log("callback.invalid_provider", {"provider": provider})
        raise HTTPException(status_code=400, detail="Provider not enabled")
    client = oauth.create_client(provider)
    client_ip = request.client.host if request.client else "unknown"
    state = request.query_params.get("state")
    if not state:
        _log("callback.missing_state", {"provider": provider})
        await audit_auth_event(None, "login_failed", {"provider": provider, "reason": "missing_state", "ip": client_ip})
        return RedirectResponse(url="/auth/error?reason=missing_state", status_code=302)
    pending = await pop_oauth_pending(state)
    if not pending:
        _log("callback.unknown_state", {"state": state})
        await audit_auth_event(None, "login_failed", {"provider": provider, "reason": "unknown_state", "ip": client_ip})
        return RedirectResponse(url="/auth/error?reason=unknown_state", status_code=302)
    code_verifier = pending["code_verifier"]
    token = None
    try:
        token = await client.authorize_access_token(request, code_verifier=code_verifier)
    except MismatchingStateError:
        _log("oauth.mismatching_state", {"provider": provider, "state": state})
        await audit_auth_event(None, "login_failed", {"provider": provider, "reason": "mismatching_state", "ip": client_ip})
        return RedirectResponse(url="/auth/error?reason=mismatching_state", status_code=302)
    except OAuthError as e:
        _log("oauth.token_exchange.oauth_error", {"provider": provider, "error": str(e)})
        await audit_auth_event(None, "login_failed", {"provider": provider, "reason": "token_exchange_failed", "error": str(e), "ip": client_ip})
        return RedirectResponse(url="/auth/error?reason=token_exchange_failed", status_code=302)
    except JoseError as e:
        _log("oauth.token_exchange.failed", {"provider": provider, "error_type": type(e).__name__})
        await audit_auth_event(None, "login_failed", {"provider": provider, "reason": "token_exchange_failed", "ip": client_ip})
        return RedirectResponse(url="/auth/error?reason=token_exchange_failed", status_code=302)
    except Exception:
        _log("oauth.token_exchange.exception", {"provider": provider})
        await audit_auth_event(None, "login_failed", {"provider": provider, "reason": "token_exchange_error", "ip": client_ip})
        return RedirectResponse(url="/auth/error?reason=token_exchange_failed", status_code=302)

    userinfo: Dict = {}
    if provider == "google":
        try:
            userinfo = await client.userinfo(token=token)
        except Exception:
            _log("google.userinfo.failed", {})
    elif provider == "microsoft":
        try:
            graph_url = "https://graph.microsoft.com/v1.0/me?$select=id,displayName,mail,userPrincipalName,tenantId"
            async with client._get_oauth_client() as http:
                resp = await http.get(graph_url, token=token)
                if resp.status_code == 200:
                    userinfo = resp.json()
        except Exception:
            _log("microsoft.graph.failed", {})

    if not userinfo:
        _log("userinfo.empty", {"provider": provider})
        await audit_auth_event(None, "login_failed", {"provider": provider, "reason": "no_userinfo", "ip": client_ip})
        return RedirectResponse(url="/auth/error?reason=no_userinfo", status_code=302)

    email = (userinfo.get("email") or userinfo.get("mail") or userinfo.get("userPrincipalName") or "").lower()
    name = userinfo.get("name") or userinfo.get("displayName") or userinfo.get("preferred_username") or (email.split("@")[0] if "@" in email else "")
    tenant_id = userinfo.get("tid") or userinfo.get("tenantId")

    if not email or "@" not in email:
        _log("userinfo.missing_email", {"provider": provider, "userinfo_keys": list(userinfo.keys())})
        await audit_auth_event(None, "login_failed", {"provider": provider, "reason": "missing_email", "ip": client_ip})
        return RedirectResponse(url="/auth/error?reason=missing_email", status_code=302)

    try:
        user_id = await upsert_user(email, provider, name, [])
        jwt_token = create_jwt(user_id, email, name, provider)
        _log("auth.success", {"user_id": user_id, "email": email, "provider": provider})
        await audit_auth_event(user_id, "login_success", {"provider": provider, "ip": client_ip})
    except Exception:
        _log("user.upsert.failed", {"email": email})
        await audit_auth_event(None, "login_failed", {"provider": provider, "reason": "user_upsert_failed", "ip": client_ip})
        return RedirectResponse(url="/auth/error?reason=internal_error", status_code=302)

    safe_front = AUTH_BASE_URL or f"{request.url.scheme}://{request.url.netloc}"
    token_js = json.dumps(jwt_token)
    return HTMLResponse(
        f"<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Redirecting...</title></head>"
        f"<body><script>try{{localStorage.setItem('app_jwt',{token_js});setTimeout(function(){{window.location.replace('{safe_front}');}},50);}}catch(e){{window.location.replace('{safe_front}');}}</script></body></html>"
    )

@app.get("/error", response_class=HTMLResponse)
async def error_page(request: Request) -> HTMLResponse:
    reason = request.query_params.get("reason", "unknown")
    messages = {
        "token_exchange_failed": "Authentication failed. Please try again.",
        "no_userinfo": "Could not retrieve your profile information.",
        "missing_email": "Your account does not have a verified email address.",
        "domain_rejected": "Your account domain is not authorized.",
        "tenant_rejected": "Your organization is not authorized.",
        "internal_error": "An internal error occurred during sign-in.",
        "missing_state": "Authentication flow did not include a state parameter.",
        "unknown_state": "Authentication state not recognized; try again.",
        "mismatching_state": "Authentication failed (state mismatch). Try again."
    }
    message = messages.get(reason, "Authentication failed.")
    safe_front = AUTH_BASE_URL or f"{request.url.scheme}://{request.url.netloc}"
    return HTMLResponse(f"<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Access Denied</title></head><body><h1>Access Denied</h1><p>{html.escape(message)}</p><p><a href='{safe_front}'>Return to application</a></p></body></html>", status_code=403)

@app.get("/me")
async def me(request: Request):
    auth = request.headers.get("authorization", "")
    if not auth or not auth.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing Authorization header")
    token = auth.split(" ", 1)[1].strip()
    try:
        payload = verify_jwt(token)
        return {"authenticated": True, "user": payload}
    except ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token expired") from None
    except InvalidTokenError as e:
        _log("jwt.invalid", {"error": str(e)})
        raise HTTPException(status_code=401, detail="Invalid token") from None
    except Exception:
        _log("jwt.decode.unexpected", {})
        raise HTTPException(status_code=401, detail="Invalid token") from None

@app.get("/logout", response_class=HTMLResponse)
async def logout(request: Request) -> HTMLResponse:
    safe_front = AUTH_BASE_URL or f"{request.url.scheme}://{request.url.netloc}"
    # If sessions stored in Valkey, clear them here (best-effort)
    try:
        # Example: if using session id stored in cookie
        sid = request.session.get("sid")
        if sid and AUTH_USE_VALKEY and valkey_client:
            try:
                await valkey_client.delete(f"auth:session:{sid}")  # best-effort and may not exist
                _log("session.revoked", {"sid": sid})
            except Exception as exc:
                _log("session.revoke.failed", {"error": repr(exc)})
    except Exception:
        # don't break logout route on internal errors
        _log("logout.internal_error", {})
    return HTMLResponse("<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Signing out...</title></head><body><script>try{localStorage.removeItem('app_jwt');}catch(e){}window.location.replace('%s');</script></body></html>" % safe_front)

