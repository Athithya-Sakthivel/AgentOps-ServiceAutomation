import os
import sys
import uuid
import time
import json
import html
import logging
from typing import Optional, Dict, List, Tuple
from urllib.parse import quote_plus

import asyncpg
from fastapi import FastAPI, Request, HTTPException, Response
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse
from authlib.integrations.starlette_client import OAuth
import jwt
from jwt.exceptions import ExpiredSignatureError, InvalidTokenError

logging.basicConfig(
    level=getattr(logging, os.getenv("LOG_LEVEL", "INFO").upper()),
    format='{"time":"%(asctime)s","level":"%(levelname)s","message":"%(message)s","logger":"%(name)s"}',
    datefmt="%Y-%m-%dT%H:%M:%S%z"
)
logger = logging.getLogger("auth")

JWT_SECRET = os.getenv("JWT_SECRET")
if not JWT_SECRET:
    logger.error("JWT_SECRET environment variable is required")
    sys.exit(1)

DATABASE_URL = os.getenv("DATABASE_URL")
if not DATABASE_URL:
    logger.error("DATABASE_URL environment variable is required")
    sys.exit(1)

JWT_EXP_SECONDS = int(os.getenv("JWT_EXP_SECONDS", "1800"))
JWT_ISS = os.getenv("JWT_ISS", "agentic-platform")
JWT_AUD = os.getenv("JWT_AUD", "agent-frontend")
GOOGLE_CLIENT_ID = os.getenv("GOOGLE_CLIENT_ID")
GOOGLE_CLIENT_SECRET = os.getenv("GOOGLE_CLIENT_SECRET")
MICROSOFT_CLIENT_ID = os.getenv("MICROSOFT_CLIENT_ID")
MICROSOFT_CLIENT_SECRET = os.getenv("MICROSOFT_CLIENT_SECRET")
MICROSOFT_TENANT_ID = os.getenv("MICROSOFT_TENANT_ID", "common")
GOOGLE_ALLOWED_DOMAINS = [d.strip().lower() for d in os.getenv("GOOGLE_ALLOWED_DOMAINS", "").split(",") if d.strip()]
MICROSOFT_ALLOWED_DOMAINS = [d.strip().lower() for d in os.getenv("MICROSOFT_ALLOWED_DOMAINS", "").split(",") if d.strip()]
MICROSOFT_ALLOWED_TENANT_IDS = [t.strip().lower() for t in os.getenv("MICROSOFT_ALLOWED_TENANT_IDS", "").split(",") if t.strip()]

oauth = OAuth()
enabled_providers: List[str] = []

if GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET:
    oauth.register(
        name="google",
        client_id=GOOGLE_CLIENT_ID,
        client_secret=GOOGLE_CLIENT_SECRET,
        server_metadata_url="https://accounts.google.com/.well-known/openid-configuration",
        client_kwargs={"scope": "openid email profile"},
    )
    enabled_providers.append("google")
    logger.info("oauth.provider.registered", extra={"provider": "google"})

if MICROSOFT_CLIENT_ID and MICROSOFT_CLIENT_SECRET:
    oauth.register(
        name="microsoft",
        client_id=MICROSOFT_CLIENT_ID,
        client_secret=MICROSOFT_CLIENT_SECRET,
        server_metadata_url=f"https://login.microsoftonline.com/{MICROSOFT_TENANT_ID}/v2.0/.well-known/openid-configuration",
        client_kwargs={"scope": "openid email profile User.Read"},
    )
    enabled_providers.append("microsoft")
    logger.info("oauth.provider.registered", extra={"provider": "microsoft", "tenant": MICROSOFT_TENANT_ID})

if not enabled_providers:
    logger.warning("no OAuth providers configured - set GOOGLE_CLIENT_ID/SECRET or MICROSOFT_CLIENT_ID/SECRET")

db_pool: Optional[asyncpg.Pool] = None

async def init_db():
    global db_pool
    try:
        db_pool = await asyncpg.create_pool(
            DATABASE_URL,
            min_size=1,
            max_size=5,
            command_timeout=10,
            init=lambda conn: conn.execute("SET application_name = 'auth-service'")
        )
        async with db_pool.acquire() as conn:
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
                CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
                CREATE INDEX IF NOT EXISTS idx_users_provider ON users(provider);
            """)
        logger.info("database.initialized")
    except Exception as e:
        logger.error("database.initialization.failed", extra={"error": str(e)})
        sys.exit(1)

async def get_user_by_email(email: str) -> Optional[Dict]:
    async with db_pool.acquire() as conn:
        row = await conn.fetchrow("SELECT id, email, provider, name FROM users WHERE email = $1", email.lower())
        return dict(row) if row else None

async def upsert_user(email: str, provider: str, name: Optional[str], allowed_orgs: List[str]) -> str:
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

def validate_domain(email: str, allowed_domains: List[str]) -> Tuple[bool, Optional[str]]:
    if not allowed_domains:
        return True, None
    try:
        domain = email.split("@", 1)[1].lower()
        if domain in allowed_domains:
            return True, None
        return False, domain
    except (IndexError, AttributeError):
        return False, None

def validate_tenant(tenant_id: Optional[str], allowed_tenants: List[str]) -> Tuple[bool, Optional[str]]:
    if not allowed_tenants:
        return True, None
    if not tenant_id:
        return False, None
    if tenant_id.lower() in allowed_tenants:
        return True, None
    return False, tenant_id

def create_jwt(user_id: str, email: str, name: Optional[str], provider: str) -> str:
    payload = {
        "iss": JWT_ISS,
        "aud": JWT_AUD,
        "sub": user_id,
        "email": email,
        "name": name or email.split("@")[0],
        "provider": provider,
        "iat": int(time.time()),
        "exp": int(time.time()) + JWT_EXP_SECONDS
    }
    return jwt.encode(payload, JWT_SECRET, algorithm="HS256")

app = FastAPI(title="Agentic Platform Auth", docs_url=None, redoc_url=None)

@app.on_event("startup")
async def startup():
    await init_db()

@app.on_event("shutdown")
async def shutdown():
    if db_pool:
        await db_pool.close()

@app.get("/health")
async def health():
    try:
        async with db_pool.acquire() as conn:
            await conn.fetchval("SELECT 1")
        return JSONResponse({"status": "ok", "database": "connected", "providers": enabled_providers})
    except Exception as e:
        logger.error("health.check.failed", extra={"error": str(e)})
        return JSONResponse({"status": "degraded", "database": "unavailable"}, status_code=503)

@app.get("/login", response_class=HTMLResponse)
async def login_page():
    if not enabled_providers:
        return HTMLResponse("<!doctype html><html><body><h2>No authentication providers configured</h2><p>Set GOOGLE_CLIENT_ID/SECRET or MICROSOFT_CLIENT_ID/SECRET</p></body></html>", status_code=503)
    
    buttons = []
    for provider in enabled_providers:
        icon = '<svg viewBox="0 0 24 24" width="18" height="18" xmlns="http://www.w3.org/2000/svg"><path fill="#EA4335" d="M12 10.2v3.6h5.2c-.2 1.2-1.4 3.6-5.2 3.6-3.1 0-5.6-2.6-5.6-5.8S8.9 6.8 12 6.8c1.8 0 2.9.8 3.6 1.5l2.4-2.3C17.2 4 14.8 3 12 3 7.6 3 4 6.6 4 11s3.6 8 8 8c4.6 0 7-3.2 7-7.7 0-.5 0-.9-.1-1.1H12z"/></svg>' if provider == "google" else '<svg viewBox="0 0 24 24" width="18" height="18" xmlns="http://www.w3.org/2000/svg"><rect x="2" y="2" width="9" height="9" fill="#F35325"/><rect x="13" y="2" width="9" height="9" fill="#81BC06"/><rect x="2" y="13" width="9" height="9" fill="#05A6F0"/><rect x="13" y="13" width="9" height="9" fill="#FFBA08"/></svg>'
        buttons.append(f'<a href="/auth/login/start/{provider}" class="w-full inline-flex items-center justify-center border rounded py-2 px-3 mb-3 hover:bg-gray-50 transition-colors" aria-label="Continue with {provider.capitalize()}">{icon}<span style="margin-left:8px">Continue with {provider.capitalize()}</span></a>')
    
    constraints = []
    if "google" in enabled_providers and GOOGLE_ALLOWED_DOMAINS:
        constraints.append(f"Google: {', '.join(GOOGLE_ALLOWED_DOMAINS)}")
    if "microsoft" in enabled_providers and MICROSOFT_ALLOWED_DOMAINS:
        constraints.append(f"Microsoft domains: {', '.join(MICROSOFT_ALLOWED_DOMAINS)}")
    if "microsoft" in enabled_providers and MICROSOFT_ALLOWED_TENANT_IDS:
        constraints.append(f"Microsoft tenants: {', '.join(MICROSOFT_ALLOWED_TENANT_IDS)}")
    
    constraints_html = f'<div class="mt-4 text-xs text-gray-600">Allowed: {html.escape("; ".join(constraints))}</div>' if constraints else ""
    
    return HTMLResponse(f"""<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<link href="https://cdn.jsdelivr.net/npm/tailwindcss@2.2.19/dist/tailwind.min.css" rel="stylesheet">
<title>Sign in to Agentic Platform</title></head>
<body class="bg-gray-50 min-h-screen flex items-center justify-center">
<div class="max-w-md w-full p-6"><div class="bg-white p-6 rounded shadow">
<h1 class="text-xl font-semibold mb-4">Sign in</h1>
{"".join(buttons)}
{constraints_html}
</div></div></body></html>""")

@app.get("/login/start/{provider}")
async def login_start(request: Request, provider: str):
    provider = provider.lower()
    if provider not in enabled_providers:
        logger.warning("login.start.invalid_provider", extra={"provider": provider, "enabled": enabled_providers})
        raise HTTPException(status_code=400, detail="Provider not enabled")
    
    client = oauth.create_client(provider)
    redirect_uri = f"{request.url.scheme}://{request.url.netloc}/auth/callback/{provider}"
    logger.info("login.start.initiated", extra={"provider": provider, "redirect_uri": redirect_uri})
    return await client.authorize_redirect(request, redirect_uri)

@app.get("/callback/{provider}")
async def callback(request: Request, provider: str):
    provider = provider.lower()
    if provider not in enabled_providers:
        logger.warning("callback.invalid_provider", extra={"provider": provider})
        raise HTTPException(status_code=400, detail="Provider not enabled")
    
    client = oauth.create_client(provider)
    try:
        token = await client.authorize_access_token(request)
    except Exception as e:
        logger.error("oauth.token_exchange.failed", extra={"provider": provider, "error": str(e)})
        return RedirectResponse(url="/auth/error?reason=token_exchange_failed", status_code=302)
    
    userinfo = {}
    if provider == "google":
        try:
            userinfo = await client.userinfo(token=token)
        except Exception as e:
            logger.error("google.userinfo.failed", extra={"error": str(e)})
    elif provider == "microsoft":
        try:
            graph_url = "https://graph.microsoft.com/v1.0/me?$select=id,displayName,mail,userPrincipalName,tenantId"
            async with client._get_oauth_client() as http:
                resp = await http.get(graph_url, token=token)
                if resp.status_code == 200:
                    userinfo = resp.json()
        except Exception as e:
            logger.error("microsoft.graph.failed", extra={"error": str(e)})
    
    if not userinfo:
        logger.error("userinfo.empty", extra={"provider": provider})
        return RedirectResponse(url="/auth/error?reason=no_userinfo", status_code=302)
    
    email = (userinfo.get("email") or userinfo.get("mail") or userinfo.get("userPrincipalName") or "").lower()
    name = userinfo.get("name") or userinfo.get("displayName") or userinfo.get("preferred_username") or email.split("@")[0]
    sub = userinfo.get("sub") or userinfo.get("id") or str(uuid.uuid4())
    tenant_id = userinfo.get("tid") or userinfo.get("tenantId")
    
    if not email or "@" not in email:
        logger.warning("userinfo.missing_email", extra={"provider": provider, "userinfo_keys": list(userinfo.keys())})
        return RedirectResponse(url="/auth/error?reason=missing_email", status_code=302)
    
    if provider == "google":
        allowed, domain = validate_domain(email, GOOGLE_ALLOWED_DOMAINS)
        if not allowed:
            logger.warning("google.domain.rejected", extra={"email": email, "domain": domain, "allowed": GOOGLE_ALLOWED_DOMAINS})
            return RedirectResponse(url=f"/auth/error?reason=domain_rejected&domain={quote_plus(domain or '')}", status_code=302)
    
    if provider == "microsoft":
        if MICROSOFT_ALLOWED_TENANT_IDS:
            allowed, tid = validate_tenant(tenant_id, MICROSOFT_ALLOWED_TENANT_IDS)
            if not allowed:
                logger.warning("microsoft.tenant.rejected", extra={"tenant_id": tid, "allowed": MICROSOFT_ALLOWED_TENANT_IDS})
                return RedirectResponse(url=f"/auth/error?reason=tenant_rejected&tenant={quote_plus(tid or '')}", status_code=302)
        
        if MICROSOFT_ALLOWED_DOMAINS:
            allowed, domain = validate_domain(email, MICROSOFT_ALLOWED_DOMAINS)
            if not allowed:
                logger.warning("microsoft.domain.rejected", extra={"email": email, "domain": domain, "allowed": MICROSOFT_ALLOWED_DOMAINS})
                return RedirectResponse(url=f"/auth/error?reason=domain_rejected&domain={quote_plus(domain or '')}", status_code=302)
    
    try:
        user_id = await upsert_user(email, provider, name, [])
        jwt_token = create_jwt(user_id, email, name, provider)
        logger.info("auth.success", extra={"user_id": user_id, "email": email, "provider": provider})
    except Exception as e:
        logger.error("user.upsert.failed", extra={"email": email, "error": str(e)})
        return RedirectResponse(url="/auth/error?reason=internal_error", status_code=302)
    
    safe_front = f"{request.url.scheme}://{request.url.netloc}"
    token_js = json.dumps(jwt_token)
    return HTMLResponse(f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Redirecting...</title></head>
<body><script>try{{localStorage.setItem('app_jwt',{token_js});setTimeout(function(){{window.location.replace('{safe_front}');}},50);}}catch(e){{window.location.replace('{safe_front}');}}</script></body></html>""")

@app.get("/error", response_class=HTMLResponse)
async def error_page(request: Request):
    reason = request.query_params.get("reason", "unknown")
    domain = request.query_params.get("domain", "")
    tenant = request.query_params.get("tenant", "")
    
    messages = {
        "token_exchange_failed": "Authentication failed. Please try again.",
        "no_userinfo": "Could not retrieve your profile information.",
        "missing_email": "Your account does not have a verified email address.",
        "domain_rejected": f"Your domain {html.escape(domain)} is not authorized to access this platform." if domain else "Your account domain is not authorized.",
        "tenant_rejected": f"Your organization (tenant {html.escape(tenant)}) is not authorized." if tenant else "Your organization is not authorized.",
        "internal_error": "An internal error occurred during sign-in."
    }
    
    message = messages.get(reason, "Authentication failed.")
    safe_front = f"{request.url.scheme}://{request.url.netloc}"
    
    return HTMLResponse(f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Access Denied</title>
<style>body{{font-family:system-ui,sans-serif;margin:40px auto;max-width:600px;text-align:center}}</style></head>
<body><h1>Access Denied</h1><p>{html.escape(message)}</p><p><a href="{safe_front}" class="text-blue-600 hover:underline">Return to application</a></p></body></html>""", status_code=403)

@app.get("/me")
async def me(request: Request):
    auth = request.headers.get("authorization", "")
    if not auth or not auth.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing Authorization header")
    
    token = auth.split(" ", 1)[1].strip()
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=["HS256"], audience=JWT_AUD, issuer=JWT_ISS)
        return {"authenticated": True, "user": payload}
    except ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token expired")
    except InvalidTokenError as e:
        logger.warning("jwt.invalid", extra={"error": str(e)})
        raise HTTPException(status_code=401, detail="Invalid token")
    except Exception as e:
        logger.error("jwt.decode.unexpected", extra={"error": str(e)})
        raise HTTPException(status_code=401, detail="Invalid token")

@app.get("/logout", response_class=HTMLResponse)
async def logout(request: Request):
    safe_front = f"{request.url.scheme}://{request.url.netloc}"
    return HTMLResponse(f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Signing out...</title></head>
<body><script>try{{localStorage.removeItem('app_jwt');}}catch(e){{}}window.location.replace('{safe_front}');</script></body></html>""")