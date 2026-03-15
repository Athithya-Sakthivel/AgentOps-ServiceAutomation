# src/services/auth/app.py
"""
Production-ready Auth FastAPI app using shared telemetry/logging/metrics.

Key points:
- Uses shared telemetry (src.services.common.telemetry.init_telemetry)
- Uses structured logger configured by the common telemetry module
- DB lifecycle handled in lifespan (connections.init_db_pool + init_db_schema)
- OAuth via Authlib
- Endpoints: /health, /ready, /login, /auth/callback, /error, /me, /logout
- No Valkey/Glide usage in this service (connections.py has no valkey)
"""
from __future__ import annotations

import base64
import hashlib
import html
import json
import os
import secrets
import time
import uuid
from contextlib import asynccontextmanager
from typing import Any

import jwt as pyjwt
from authlib.integrations.base_client.errors import MismatchingStateError, OAuthError

# authlib
from authlib.integrations.starlette_client import OAuth
from authlib.jose.errors import JoseError
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from jwt import ExpiredSignatureError, InvalidTokenError

# db helpers (absolute import)
from src.services.auth import connections

# shared telemetry & helpers (absolute import)
from src.services.common.telemetry import get_meter, get_tracer, init_telemetry
from starlette.middleware.base import BaseHTTPMiddleware

# -------------------------
# Configuration (env)
# -------------------------
SERVICE_NAME = os.getenv("SERVICE_NAME", "auth")
SERVICE_VERSION = os.getenv("SERVICE_VERSION", "0.0.0")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
DATABASE_URL = os.getenv("DATABASE_URL")
JWT_SECRET = os.getenv("JWT_SECRET")
JWT_SECRET_PREVIOUS = os.getenv("JWT_SECRET_PREVIOUS", "")
SESSION_SECRET = os.getenv("SESSION_SECRET", "dev-session-secret")
AUTH_BASE_URL = os.getenv("AUTH_BASE_URL", "")
JWT_EXP_SECONDS = int(os.getenv("JWT_EXP_SECONDS", "1800"))
JWT_ISS = os.getenv("JWT_ISS", "agentic-platform")
JWT_AUD = os.getenv("JWT_AUD", "agent-frontend")

GOOGLE_CLIENT_ID = os.getenv("GOOGLE_CLIENT_ID")
GOOGLE_CLIENT_SECRET = os.getenv("GOOGLE_CLIENT_SECRET")
MICROSOFT_CLIENT_ID = os.getenv("MICROSOFT_CLIENT_ID")
MICROSOFT_CLIENT_SECRET = os.getenv("MICROSOFT_CLIENT_SECRET")
MICROSOFT_TENANT_ID = os.getenv("MICROSOFT_TENANT_ID", "common")

STARTUP_RETRIES = int(os.getenv("STARTUP_RETRIES", "3"))
STARTUP_BASE_DELAY = float(os.getenv("STARTUP_BASE_DELAY", "0.5"))

# minimal checks
_missing = [k for k, v in {"DATABASE_URL": DATABASE_URL, "JWT_SECRET": JWT_SECRET}.items() if not v]
if _missing:
    raise SystemExit(f"Missing env vars for auth service: {', '.join(_missing)}")

# -------------------------
# Initialize telemetry & logger early (before creating DB pools)
# -------------------------
# prefer OTEL_EXPORTER_OTLP_ENDPOINT env or use default insecure localhost:4317 for local dev
init_telemetry(service_name=SERVICE_NAME, service_version=SERVICE_VERSION, otlp_insecure=True)
import logging

logger = logging.getLogger("auth")
tracer = get_tracer("auth")  # used for manual spans if needed
meter = get_meter("auth")
# instruments can be created from a separate module (metrics helper). Keep optional.
try:
    from src.services.common.metrics import ensure_common_instruments  # type: ignore
except Exception:
    ensure_common_instruments = None  # type: ignore

_instruments: dict[str, Any] = {}
try:
    if ensure_common_instruments and meter:
        _instruments = ensure_common_instruments(meter) or {}
except Exception:
    logger.exception("metrics.instruments.failed")

# -------------------------
# FastAPI app & middleware
# -------------------------
app = FastAPI(title="Auth Service", version=SERVICE_VERSION)


class RequestIDMiddleware(BaseHTTPMiddleware):
    """Attach X-Request-ID to request.state and response header."""

    async def dispatch(self, request: Request, call_next):
        # prefer incoming header, else generate
        reqid = request.headers.get("x-request-id") or request.headers.get("X-Request-ID")
        if not reqid:
            reqid = str(uuid.uuid4())
        # ensure state attribute exists and set request_id
        try:
            request.state.request_id = reqid
        except Exception:
            # fallback: ensure request.scope["state"] is an object with attribute
            st = request.scope.get("state")
            if st is None:
                class _S: ...
                st = _S()
                request.scope["state"] = st
            st.request_id = reqid
        # proceed
        response = await call_next(request)
        # expose header for downstream visibility
        try:
            response.headers["X-Request-ID"] = reqid
        except Exception:
            pass
        return response


app.add_middleware(RequestIDMiddleware)

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
    logger.info("oauth.provider.registered", extra={"event": "oauth.provider.registered", "provider": "google"})

if MICROSOFT_CLIENT_ID and MICROSOFT_CLIENT_SECRET:
    oauth.register(
        name="microsoft",
        client_id=MICROSOFT_CLIENT_ID,
        client_secret=MICROSOFT_CLIENT_SECRET,
        server_metadata_url=f"https://login.microsoftonline.com/{MICROSOFT_TENANT_ID}/v2.0/.well-known/openid-configuration",
        client_kwargs={"scope": "openid email profile User.Read"},
    )
    enabled_providers.append("microsoft")
    logger.info("oauth.provider.registered", extra={"event": "oauth.provider.registered", "provider": "microsoft", "tenant": MICROSOFT_TENANT_ID})

if not enabled_providers:
    logger.info("no_oauth_providers_configured", extra={"event": "no_oauth_providers_configured"})

# -------------------------
# Globals that will be set in lifespan
# -------------------------
db_pool = None  # type: ignore

# -------------------------
# utility functions
# -------------------------
def make_state() -> str:
    return secrets.token_urlsafe(32)


def make_code_verifier() -> str:
    return secrets.token_urlsafe(64)


def code_challenge_from_verifier(verifier: str) -> str:
    sha = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(sha).rstrip(b"=").decode("ascii")


def create_jwt(user_id: str, email: str, name: str | None, provider: str) -> str:
    iat = int(time.time())
    payload = {
        "iss": JWT_ISS,
        "aud": JWT_AUD,
        "sub": user_id,
        "email": email,
        "name": name or (email.split("@")[0] if "@" in email else ""),
        "provider": provider,
        "iat": iat,
        "exp": iat + JWT_EXP_SECONDS,
    }
    return pyjwt.encode(payload, JWT_SECRET, algorithm="HS256")


def verify_jwt(token: str) -> dict[str, Any]:
    # try current + previous for rotation
    for secret in (JWT_SECRET, JWT_SECRET_PREVIOUS):
        if not secret:
            continue
        try:
            return pyjwt.decode(token, secret, algorithms=["HS256"], audience=JWT_AUD, issuer=JWT_ISS)
        except ExpiredSignatureError:
            raise
        except InvalidTokenError:
            continue
    raise InvalidTokenError("No valid secret found")


# -------------------------
# Lifespan - create/teardown DB pool & ensure schema
# -------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    global db_pool
    logger.info("startup.init", extra={"event": "startup.init", "database_url": connections.mask_dsn(DATABASE_URL)})
    db_pool = await connections.init_db_pool(DATABASE_URL, min_size=1, max_size=10, command_timeout=5)
    logger.info("database.pool.created", extra={"event": "database.pool.created", "min_size": 1, "max_size": 10})
    try:
        await connections.init_db_schema(db_pool)
        logger.info("database.migrate.complete", extra={"event": "database.migrate.complete"})
    except Exception:
        logger.exception("database.migrate.failed", extra={"event": "database.migrate.failed"})
        raise

    # instruments registration: if meter present, ensure we have instruments
    try:
        if meter and ensure_common_instruments:
            ensure_common_instruments(meter)
    except Exception:
        logger.exception("metrics.instruments.failed", extra={"event": "metrics.instruments.failed"})

    try:
        yield
    finally:
        logger.info("shutdown.start", extra={"event": "shutdown.start"})
        if db_pool:
            try:
                await db_pool.close()
                logger.info("database.pool.closed", extra={"event": "database.pool.closed"})
            except Exception:
                logger.exception("database.pool.close.failed", extra={"event": "database.pool.close.failed"})
        logger.info("shutdown.complete", extra={"event": "shutdown.complete"})


app.router.lifespan_context = lifespan  # type: ignore

# -------------------------
# Endpoints
# -------------------------
@app.get("/health")
async def health():
    ok = bool(db_pool)
    return JSONResponse({"status": "ok" if ok else "degraded", "database": "connected" if ok else "unavailable", "providers": enabled_providers})


@app.get("/ready")
async def ready():
    if not db_pool:
        return JSONResponse({"status": "not_ready", "reason": "db_unavailable"}, status_code=503)
    if not enabled_providers:
        return JSONResponse({"status": "not_ready", "reason": "no_providers"}, status_code=503)
    return JSONResponse({"status": "ready"})


@app.get("/login", response_class=HTMLResponse)
async def login_page():
    if not enabled_providers:
        return HTMLResponse("<!doctype html><html><body><h2>No auth providers configured</h2></body></html>", status_code=503)
    buttons = [f'<a href="/auth/login/start/{p}">Continue with {p.capitalize()}</a>' for p in enabled_providers]
    return HTMLResponse("<!doctype html><html><body>" + "".join(buttons) + "</body></html>")


@app.get("/auth/login/start/{provider}")
async def login_start(request: Request, provider: str) -> Response:
    provider = provider.lower()
    reqid = getattr(request.state, "request_id", None)
    if provider not in enabled_providers:
        logger.info("login.start.invalid_provider", extra={"event": "login.start.invalid_provider", "provider": provider, "reqid": reqid})
        raise HTTPException(status_code=400, detail="Provider not enabled")
    client = oauth.create_client(provider)
    base = AUTH_BASE_URL or f"{request.url.scheme}://{request.url.netloc}"
    redirect_uri = f"{base}/auth/callback/{provider}"
    client_ip = request.client.host if request.client else "unknown"
    state = make_state()
    code_verifier = make_code_verifier()
    code_challenge = code_challenge_from_verifier(code_verifier)
    try:
        await connections.save_oauth_pending(db_pool, state=state, provider=provider, code_verifier=code_verifier, redirect_uri=redirect_uri, ip_address=client_ip)
    except Exception:
        logger.exception("save_oauth_pending.failed", extra={"event": "save_oauth_pending.failed", "reqid": reqid})
        raise HTTPException(status_code=500, detail="internal_error")
    logger.info("login.start.initiated", extra={"event": "login.start.initiated", "provider": provider, "redirect_uri": redirect_uri, "reqid": reqid})
    try:
        return await client.authorize_redirect(request, redirect_uri, state=state, code_challenge=code_challenge, code_challenge_method="S256")
    except Exception:
        try:
            await connections.pop_oauth_pending(db_pool, state)
        except Exception:
            logger.exception("cleanup.pop_oauth_pending.failed", extra={"event": "cleanup.pop_oauth_pending.failed", "reqid": reqid})
        logger.exception("login.start.provider_error", extra={"event": "login.start.provider_error", "reqid": reqid})
        raise HTTPException(status_code=502, detail="provider_error")


@app.get("/auth/callback/{provider}")
async def callback(request: Request, provider: str) -> Response:
    provider = provider.lower()
    reqid = getattr(request.state, "request_id", None)
    if provider not in enabled_providers:
        logger.info("callback.invalid_provider", extra={"event": "callback.invalid_provider", "provider": provider, "reqid": reqid})
        raise HTTPException(status_code=400, detail="Provider not enabled")
    client = oauth.create_client(provider)
    client_ip = request.client.host if request.client else "unknown"
    state = request.query_params.get("state")
    if not state:
        logger.info("callback.missing_state", extra={"event": "callback.missing_state", "provider": provider, "reqid": reqid})
        await connections.audit_auth_event(db_pool, None, "login_failed", {"provider": provider, "reason": "missing_state", "ip": client_ip})
        return RedirectResponse(url="/auth/error?reason=missing_state", status_code=302)
    pending = await connections.pop_oauth_pending(db_pool, state)
    if not pending:
        logger.info("callback.unknown_state", extra={"event": "callback.unknown_state", "state": state, "reqid": reqid})
        await connections.audit_auth_event(db_pool, None, "login_failed", {"provider": provider, "reason": "unknown_state", "ip": client_ip})
        return RedirectResponse(url="/auth/error?reason=unknown_state", status_code=302)
    code_verifier = pending["code_verifier"]
    token = None
    try:
        token = await client.authorize_access_token(request, code_verifier=code_verifier)
    except MismatchingStateError:
        logger.info("oauth.mismatching_state", extra={"event": "oauth.mismatching_state", "provider": provider, "state": state, "reqid": reqid})
        await connections.audit_auth_event(db_pool, None, "login_failed", {"provider": provider, "reason": "mismatching_state", "ip": client_ip})
        return RedirectResponse(url="/auth/error?reason=mismatching_state", status_code=302)
    except OAuthError as e:
        logger.exception("oauth.token_exchange.oauth_error", extra={"event": "oauth.token_exchange.oauth_error", "reqid": reqid})
        await connections.audit_auth_event(db_pool, None, "login_failed", {"provider": provider, "reason": "token_exchange_failed", "error": str(e), "ip": client_ip})
        return RedirectResponse(url="/auth/error?reason=token_exchange_failed", status_code=302)
    except JoseError:
        logger.exception("oauth.token_exchange.failed", extra={"event": "oauth.token_exchange.failed", "reqid": reqid})
        await connections.audit_auth_event(db_pool, None, "login_failed", {"provider": provider, "reason": "token_exchange_failed", "ip": client_ip})
        return RedirectResponse(url="/auth/error?reason=token_exchange_failed", status_code=302)
    except Exception:
        logger.exception("oauth.token_exchange.exception", extra={"event": "oauth.token_exchange.exception", "reqid": reqid})
        await connections.audit_auth_event(db_pool, None, "login_failed", {"provider": provider, "reason": "token_exchange_error", "ip": client_ip})
        return RedirectResponse(url="/auth/error?reason=token_exchange_failed", status_code=302)

    userinfo: dict[str, Any] = {}
    if provider == "google":
        try:
            userinfo = await client.userinfo(token=token)
        except Exception:
            logger.exception("google.userinfo.failed", extra={"event": "google.userinfo.failed", "reqid": reqid})
    elif provider == "microsoft":
        try:
            graph_url = "https://graph.microsoft.com/v1.0/me?$select=id,displayName,mail,userPrincipalName,tenantId"
            async with client._get_oauth_client() as http:
                resp = await http.get(graph_url, token=token)
                if resp.status_code == 200:
                    userinfo = resp.json()
        except Exception:
            logger.exception("microsoft.graph.failed", extra={"event": "microsoft.graph.failed", "reqid": reqid})

    if not userinfo:
        logger.info("userinfo.empty", extra={"event": "userinfo.empty", "provider": provider, "reqid": reqid})
        await connections.audit_auth_event(db_pool, None, "login_failed", {"provider": provider, "reason": "no_userinfo", "ip": client_ip})
        return RedirectResponse(url="/auth/error?reason=no_userinfo", status_code=302)

    email = (userinfo.get("email") or userinfo.get("mail") or userinfo.get("userPrincipalName") or "").lower()
    name = userinfo.get("name") or userinfo.get("displayName") or userinfo.get("preferred_username") or (email.split("@")[0] if "@" in email else "")

    if not email or "@" not in email:
        logger.info("userinfo.missing_email", extra={"event": "userinfo.missing_email", "provider": provider, "userinfo_keys": list(userinfo.keys()), "reqid": reqid})
        await connections.audit_auth_event(db_pool, None, "login_failed", {"provider": provider, "reason": "missing_email", "ip": client_ip})
        return RedirectResponse(url="/auth/error?reason=missing_email", status_code=302)

    try:
        user_id = await connections.upsert_user(db_pool, email=email, provider=provider, name=name, allowed_orgs=[])
        jwt_token = create_jwt(user_id, email, name, provider)
        logger.info("auth.success", extra={"event": "auth.success", "user_id": user_id, "email": email, "provider": provider, "reqid": reqid})
        await connections.audit_auth_event(db_pool, user_id, "login_success", {"provider": provider, "ip": client_ip})
    except Exception:
        logger.exception("user.upsert.failed", extra={"event": "user.upsert.failed", "reqid": reqid})
        await connections.audit_auth_event(db_pool, None, "login_failed", {"provider": provider, "reason": "user_upsert_failed", "ip": client_ip})
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
    reqid = getattr(request.state, "request_id", None)
    if not auth or not auth.lower().startswith("bearer "):
        logger.info("jwt.missing", extra={"event": "jwt.missing", "reqid": reqid})
        raise HTTPException(status_code=401, detail="Missing Authorization header")
    token = auth.split(" ", 1)[1].strip()
    try:
        payload = verify_jwt(token)
        return {"authenticated": True, "user": payload}
    except ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token expired") from None
    except InvalidTokenError as e:
        logger.info("jwt.invalid", extra={"event": "jwt.invalid", "error": str(e), "reqid": reqid})
        raise HTTPException(status_code=401, detail="Invalid token") from None
    except Exception:
        logger.exception("jwt.decode.unexpected", extra={"event": "jwt.decode.unexpected", "reqid": reqid})
        raise HTTPException(status_code=401, detail="Invalid token") from None


@app.get("/logout", response_class=HTMLResponse)
async def logout(request: Request) -> HTMLResponse:
    safe_front = AUTH_BASE_URL or f"{request.url.scheme}://{request.url.netloc}"
    reqid = getattr(request.state, "request_id", None)
    # session cookie removal; we do not use valkey here
    try:
        sid = getattr(request, "session", {}).get("sid") if hasattr(request, "session") else None
        if sid:
            logger.info("logout.session_found", extra={"event": "logout.session_found", "sid": sid, "reqid": reqid})
    except Exception:
        logger.exception("logout.internal_error", extra={"event": "logout.internal_error", "reqid": reqid})
    return HTMLResponse("<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Signing out...</title></head><body><script>try{localStorage.removeItem('app_jwt');}catch(e){}window.location.replace('%s');</script></body></html>" % safe_front)
