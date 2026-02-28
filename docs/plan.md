Agentic AI platform for automated customer actions. Cloud-agnostic, Kubernetes-native, no cloud LB dependency.

Architecture:

User → Cloudflare Edge → cloudflared (in cluster) → NGINX Ingress →
• SPA (NGINX)
• RayService (FastAPI + LangGraph + MCP)
• Postgres (StatefulSet)

Core stack:

Frontend: React (Vite) + NGINX, 2 replicas, stateless.
Backend: FastAPI running inside Ray Serve (via KubeRay RayService).
Database: Postgres StatefulSet, single replica, PVC-backed.
Edge: Cloudflare tunnel (outbound only, no exposed ports).

LangGraph:

Nodes: LoadState → Intent → ToolDecision → ToolExec → Approval → Persist → Respond.
State checkpoint after each node (Postgres JSONB).
Supports retries and resumable approval flows.

MCP tool layer:

Tool interface: name, schema, execute().
Strict schema validation before execution.
Whitelist registry.
LLM outputs structured tool calls only.

Auth:

JWT, stateless.
Roles: user, admin.
Refunds above threshold trigger approval → graph pauses → resumes on approval.

Persistence:

Postgres only.
Stores users, sessions, workflow state, approvals, audit logs.
No Redis.

Scaling:

Ray Serve autoscaling (min 1, max 5).
Trigger: concurrent requests / CPU.
Frontend scales independently.
Cloudflare absorbs traffic spikes.

Security:

K8s Secrets.
No public DB.
Cloudflare WAF + rate limiting.
Schema validation before tool execution.

Local → Prod path:

Docker Compose (Postgres + backend + frontend)

kind/k3d

Add KubeRay

Add Ingress

Add cloudflared tunnel

Folder layout:

backend/ (app, auth, db, agent, tools, api, Dockerfile)
frontend/ (src, Dockerfile)
k8s/ (namespace, postgres, rayservice, frontend, ingress, cloudflared)

Cloud-agnostic because:

No managed DB.
No cloud load balancer.
No cloud IAM coupling.
Runs on any Kubernetes cluster.

Minimal, scalable, and production-correct without unnecessary components.