# `src/services/auth/README.md`

## Overview

The **Auth Service** is a dedicated authentication gateway responsible for user identity verification, OAuth login, session handling, and JWT issuance for the platform.

It operates as a **stateless FastAPI service** backed by **PostgreSQL** and integrates with external OAuth providers (Google, Microsoft). The service exposes a small set of endpoints used by the frontend and downstream internal services.

Primary responsibilities:

* OAuth login orchestration
* PKCE security enforcement
* session lifecycle management
* JWT token issuance
* user identity persistence
* audit logging

The service is designed to run **horizontally scalable in Kubernetes**.

---

# System Architecture

```
┌────────────────────┐
│      Browser       │
│  (Frontend App)   │
└─────────┬──────────┘
          │ HTTPS
          ▼
┌────────────────────┐
│   Frontend App     │
│  (React / Web UI)  │
└─────────┬──────────┘
          │
          │ OAuth Login Redirect
          ▼
┌────────────────────────────┐
│       Auth Service         │
│     FastAPI / Uvicorn      │
│                            │
│  - OAuth flow controller   │
│  - PKCE verification       │
│  - JWT issuance            │
│  - session cookies         │
│  - audit logging           │
└───────────┬────────────────┘
            │
            │ SQL
            ▼
┌────────────────────────────┐
│        PostgreSQL          │
│                            │
│ tables:                    │
│ - users                    │
│ - oauth_pending            │
│ - audit_logs               │
└────────────────────────────┘
```

External OAuth Providers:

```
Google OAuth
Microsoft Entra ID
```

---

# Runtime Mental Model

Auth service runs as a **pure OAuth orchestration layer**.

Think of the system as **three stages**:

```
Stage 1: Login Initialization
Stage 2: OAuth Callback Processing
Stage 3: Session / Token Consumption
```

Each stage has strict input/output contracts.

---

# Control Flow

## 1. Login Initialization

User clicks login button.

```
Browser
   │
   │ GET /auth/login/start/{provider}
   ▼
Auth Server
```

Auth service performs:

1. Generate cryptographically secure values

```
state
code_verifier
code_challenge
```

2. Store pending login state

```
oauth_pending table
```

Fields stored:

```
state
provider
code_verifier
created_at
```

3. Redirect user to provider authorization endpoint.

```
302 Redirect → Google/Microsoft OAuth
```

PKCE protects against authorization code interception.

---

## 2. OAuth Provider Interaction

User authenticates with provider.

Provider redirects back:

```
GET /auth/callback/{provider}
```

Query parameters:

```
code
state
```

---

## 3. Callback Processing

Auth service verifies:

1. `state` exists in `oauth_pending`
2. `code_verifier` matches PKCE
3. provider token exchange succeeds
4. email/domain allow-list rules pass

If validation succeeds:

```
create or update user
```

User identity fields:

```
email
name
provider
provider_user_id
```

Stored in:

```
users table
```

Audit record inserted:

```
action = login_success
```

If validation fails:

```
audit_logs action = login_failed
```

---

# Token Issuance

After successful authentication:

Auth service generates a **JWT**.

JWT characteristics:

```
algorithm: HS256
issuer: agentic-platform
audience: agent-frontend
```

JWT payload:

```
sub      user UUID
email    user email
name     display name
provider oauth provider
iat      issued time
exp      expiration
```

Token lifetime:

```
1 hour default
```

JWT returned via **secure cookie** or **frontend redirect** depending on configuration.

---

# Session Model

Two mechanisms may coexist.

### 1. JWT Bearer

Frontend sends:

```
Authorization: Bearer <token>
```

Used by:

```
/me endpoint
internal APIs
```

### 2. HTTP-only Session Cookie

Cookie properties:

```
HttpOnly
Secure
SameSite=Lax
```

Used for browser session continuity.

---

# API Endpoints

## Health

```
GET /health
```

Response:

```
{
  "status": "ok",
  "database": "connected",
  "providers": ["google","microsoft"]
}
```

Used by:

```
k8s readiness
monitoring
```

---

## Readiness

```
GET /ready
```

Response:

```
{"status":"ready"}
```

or

```
{"status":"not_ready"}
```

---

## Login Page

```
GET /login
```

Returns HTML login UI containing provider buttons.

---

## Start OAuth

```
GET /auth/login/start/{provider}
```

Redirects to provider authorization endpoint.

Side effects:

```
insert oauth_pending
set session cookie
```

---

## OAuth Callback

```
GET /auth/callback/{provider}
```

Query parameters:

```
code
state
```

Performs:

```
token exchange
identity fetch
user persistence
JWT issuance
```

---

## User Info

```
GET /me
```

Authentication:

```
Authorization: Bearer <jwt>
```

Response:

```
{
  "sub": "...",
  "email": "...",
  "name": "...",
  "provider": "google"
}
```

---

## Logout

```
GET /logout
```

Behavior:

```
clear session cookie
invalidate local session
```

---

# Database Schema

## users

```
id UUID PK
email TEXT UNIQUE
name TEXT
provider TEXT
provider_user_id TEXT
created_at TIMESTAMP
```

---

## oauth_pending

Temporary storage for PKCE login flows.

```
state TEXT PK
provider TEXT
code_verifier TEXT
created_at TIMESTAMP
```

Entries should expire after short TTL.

---

## audit_logs

```
timestamp TIMESTAMP
action TEXT
details JSONB
```

Examples:

```
login_success
login_failed
logout
```

---

# Kubernetes Deployment Model

Auth service runs as a stateless deployment.

```
Deployment
  replicas: 2+
```

Scaling horizontally is safe because:

```
session state stored in DB
PKCE state stored in DB
JWT self-contained
```

---

## Typical Kubernetes Objects

```
Deployment
Service
ConfigMap
Secret
```

---

### Deployment

```
auth-service
```

Container:

```
python
uvicorn
fastapi
```

Command:

```
uvicorn src.services.auth.auth_server:app
```

---

### Service

Cluster internal service.

```
auth-service.default.svc.cluster.local
```

Port:

```
8000
```

Frontend communicates through ingress.

---

### Ingress

Routes:

```
/login
/auth/*
/me
/logout
```

to auth service.

---

### Secrets

Sensitive configuration stored in Kubernetes secrets.

Examples:

```
JWT_SECRET
SESSION_SECRET
GOOGLE_CLIENT_SECRET
MICROSOFT_CLIENT_SECRET
DATABASE_URL
```

---

### ConfigMap

Non-secret runtime config.

Examples:

```
ALLOWED_EMAIL_DOMAINS
OAUTH_REDIRECT_URL
FRONTEND_BASE_URL
```

---

# Environment Variables

Required:

```
DATABASE_URL
SESSION_SECRET
JWT_SECRET
```

Optional:

```
COOKIE_SECURE
SESSION_COOKIE_SECURE
FRONTEND_BASE_URL
```

Provider credentials:

```
GOOGLE_CLIENT_ID
GOOGLE_CLIENT_SECRET
MICROSOFT_CLIENT_ID
MICROSOFT_CLIENT_SECRET
```

---

# Frontend Integration Contract

Frontend does not implement OAuth logic.

Instead it interacts with auth server endpoints.

---

## Login Flow

Frontend redirects user:

```
/login
```

User clicks provider.

OAuth flow handled entirely by auth service.

---

## Authenticated API Calls

Frontend must include JWT.

```
Authorization: Bearer <token>
```

Used when calling:

```
/me
backend APIs
```

---

## Logout

Frontend triggers:

```
GET /logout
```

Then clears local session.

---

# Security Model

Protections implemented:

### PKCE

Prevents authorization code interception.

### State parameter

Prevents CSRF in OAuth flow.

### Domain allow-listing

Restricts login to approved email domains.

### HttpOnly cookies

Prevents JavaScript token access.

### Audit logs

Tracks authentication attempts.

---

# Observability

Logs include:

```
oauth.provider.registered
database.initialized
login_success
login_failed
```

Kubernetes monitoring should watch:

```
/health
/ready
```

---

# Failure Modes

Typical failure scenarios:

### OAuth provider unavailable

Login start still succeeds but callback fails.

### PKCE state expired

Callback rejected.

### Database unavailable

Service reports:

```
/health database: disconnected
```

### Invalid JWT

`/me` returns:

```
401 unauthorized
```

---

# Operational Mental Model

Think of the auth service as:

```
OAuth Controller
+ Identity Store
+ Token Issuer
```

It does **not** handle application permissions or RBAC.

Downstream services should only trust:

```
validated JWTs
```
