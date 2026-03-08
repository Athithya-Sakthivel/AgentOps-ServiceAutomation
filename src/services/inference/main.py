import os
import sys
import uuid
import json
import time
import logging
from typing import Dict, Any, Optional
from contextlib import asynccontextmanager
import jwt
from jwt.exceptions import ExpiredSignatureError, InvalidTokenError
from fastapi import FastAPI, Request, HTTPException, Depends, Header
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from langgraph.checkpoint.postgres import PostgresSaver
from agents import create_graph, AgentState
from pg_tables import init_db
from telemetry import setup_telemetry
import asyncpg

logging.basicConfig(
    level=getattr(logging, os.getenv("LOG_LEVEL", "INFO").upper()),
    format='{"time":"%(asctime)s","level":"%(levelname)s","message":"%(message)s","logger":"%(name)s"}',
    datefmt="%Y-%m-%dT%H:%M:%S%z"
)
logger = logging.getLogger("main")

JWT_SECRET = os.getenv("JWT_SECRET")
if not JWT_SECRET:
    logger.error("JWT_SECRET environment variable required")
    sys.exit(1)

JWT_ISS = os.getenv("JWT_ISS", "agentic-platform")
JWT_AUD = os.getenv("JWT_AUD", "agent-frontend")
DATABASE_URL = os.getenv("DATABASE_URL")
if not DATABASE_URL:
    logger.error("DATABASE_URL environment variable required")
    sys.exit(1)

checkpointer: Optional[PostgresSaver] = None
graph = None
meter = None
tracer = None

request_counter = None
request_duration_histogram = None
error_counter = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global checkpointer, graph, tracer, meter, request_counter, request_duration_histogram, error_counter
    
    logger.info("application.startup.begin")
    
    await init_db()
    
    checkpointer = PostgresSaver.from_conn_string(DATABASE_URL)
    graph = create_graph(checkpointer)
    logger.info("langgraph.checkpointer.initialized")
    
    tracer, meter = setup_telemetry(app)
    logger.info("telemetry.initialized")
    
    request_counter = meter.create_counter(
        name="chat_requests_total",
        description="Total number of chat requests",
        unit="1"
    )
    
    request_duration_histogram = meter.create_histogram(
        name="chat_request_duration_seconds",
        description="Duration of chat requests",
        unit="s"
    )
    
    error_counter = meter.create_counter(
        name="chat_errors_total",
        description="Total number of chat errors",
        unit="1"
    )
    
    logger.info("metrics.initialized")
    
    yield
    
    logger.info("application.shutdown.complete")

app = FastAPI(
    title="Agentic Customer Service Platform",
    version="1.0.0",
    lifespan=lifespan,
    docs_url=None,
    redoc_url=None
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

async def verify_jwt(authorization: str = Header(...)) -> Dict[str, Any]:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing or invalid Authorization header")
    
    token = authorization.split(" ", 1)[1].strip()
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=["HS256"], audience=JWT_AUD, issuer=JWT_ISS)
        return payload
    except ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token expired")
    except InvalidTokenError as e:
        logger.warning(f"jwt.invalid error={str(e)}")
        raise HTTPException(status_code=401, detail="Invalid token")
    except Exception as e:
        logger.error(f"jwt.decode.unexpected error={str(e)}")
        raise HTTPException(status_code=401, detail="Invalid token")

@app.get("/health")
async def health():
    return JSONResponse({
        "status": "ok",
        "service": "agentic-agent",
        "graph_ready": graph is not None
    })

@app.post("/chat")
async def chat(request: Request, payload: Dict[str, Any], user: Dict[str, Any] = Depends(verify_jwt)):
    global request_counter, request_duration_histogram, error_counter
    
    start_time = time.time()
    
    with tracer.start_as_current_span("chat.request") as span:
        span.set_attribute("user.id", user["sub"])
        span.set_attribute("user.email", user["email"])
        
        session_id = payload.get("session_id") or str(uuid.uuid4())
        message = payload.get("message", "").strip()
        
        if not message:
            raise HTTPException(status_code=400, detail="Message content required")
        
        logger.info(f"chat.request.received session_id={session_id} user_id={user['sub']} message_preview={message[:50]}")
        
        initial_state: AgentState = {
            "session_id": session_id,
            "user_id": user["sub"],
            "messages": [{"role": "user", "content": message}],
            "current_tool": None,
            "tool_args": None,
            "tool_result": None,
            "approval_required": False,
            "approval_status": None,
            "approval_reason": None,
            "error": None,
            "completed": False
        }
        
        try:
            request_counter.add(1, {"status": "processing", "user_id": user["sub"]})
            
            final_state = await graph.ainvoke(initial_state, config={"configurable": {"thread_id": session_id}})
            
            duration = time.time() - start_time
            request_duration_histogram.record(duration, {"status": "success"})
            
            if final_state.get("error"):
                error_counter.add(1, {"error_type": "agent_error", "session_id": session_id})
                logger.error(f"chat.execution.failed session_id={session_id} error={final_state['error']}")
                return JSONResponse({
                    "session_id": session_id,
                    "response": f"Error: {final_state['error']}",
                    "completed": True,
                    "error": final_state["error"]
                }, status_code=500)
            
            response_message = final_state["messages"][-1]["content"]
            
            logger.info(
                f"chat.request.completed session_id={session_id} "
                f"response_preview={response_message[:100]} "
                f"tool_used={final_state.get('current_tool')} "
                f"approval_pending={final_state.get('approval_required', False) and not final_state.get('approval_status')}"
            )
            
            return JSONResponse({
                "session_id": session_id,
                "response": response_message,
                "completed": final_state["completed"],
                "tool_used": final_state.get("current_tool"),
                "approval_pending": final_state.get("approval_required", False) and not final_state.get("approval_status")
            })
        
        except Exception as e:
            duration = time.time() - start_time
            request_duration_histogram.record(duration, {"status": "error"})
            error_counter.add(1, {"error_type": "exception", "session_id": session_id})
            logger.exception(f"chat.unexpected.error session_id={session_id} error={str(e)}")
            return JSONResponse({
                "session_id": session_id,
                "response": "An unexpected error occurred. Please try again.",
                "completed": True,
                "error": str(e)
            }, status_code=500)

@app.post("/approve")
async def approve(request: Request, payload: Dict[str, Any], user: Dict[str, Any] = Depends(verify_jwt)):
    with tracer.start_as_current_span("approval.request") as span:
        span.set_attribute("approver.id", user["sub"])
        
        approval_id = payload.get("approval_id")
        action = payload.get("action")
        reason = payload.get("reason", "")
        
        if not approval_id or action not in ["approve", "reject"]:
            raise HTTPException(status_code=400, detail="approval_id and action (approve/reject) required")
        
        conn = await asyncpg.connect(DATABASE_URL)
        try:
            row = await conn.fetchrow("""
                SELECT session_id, user_id, tool_name, tool_args 
                FROM approvals 
                WHERE id = $1 AND status = 'pending'
                FOR UPDATE SKIP LOCKED
            """, approval_id)
            
            if not row:
                raise HTTPException(status_code=404, detail="Approval request not found or already processed")
            
            session_id = str(row["session_id"])
            requester_id = str(row["user_id"])
            tool_name = row["tool_name"]
            tool_args = json.loads(row["tool_args"])
            
            status = "approved" if action == "approve" else "rejected"
            
            await conn.execute("""
                UPDATE approvals 
                SET status = $1, resolved_by = $2, resolved_at = NOW(), reason = $3
                WHERE id = $4
            """, status, user["sub"], reason, approval_id)
            
            logger.info(f"approval.resolved approval_id={approval_id} session_id={session_id} action={action} approver={user['sub']}")
            
            if action == "approve":
                initial_state: AgentState = {
                    "session_id": session_id,
                    "user_id": requester_id,
                    "messages": [{"role": "user", "content": "Resume after approval"}],
                    "current_tool": tool_name,
                    "tool_args": tool_args,
                    "tool_result": None,
                    "approval_required": False,
                    "approval_status": "approved",
                    "approval_reason": None,
                    "error": None,
                    "completed": False
                }
                
                final_state = await graph.ainvoke(initial_state, config={"configurable": {"thread_id": session_id}})
                response_message = final_state["messages"][-1]["content"]
                
                return JSONResponse({
                    "approval_id": approval_id,
                    "status": "approved",
                    "session_id": session_id,
                    "response": response_message
                })
            else:
                return JSONResponse({
                    "approval_id": approval_id,
                    "status": "rejected",
                    "session_id": session_id,
                    "message": "Request rejected by manager"
                })
        
        finally:
            await conn.close()

@app.get("/approvals/pending")
async def pending_approvals(user: Dict[str, Any] = Depends(verify_jwt)):
    conn = await asyncpg.connect(DATABASE_URL)
    try:
        rows = await conn.fetch("""
            SELECT a.id, a.session_id, a.tool_name, a.tool_args, a.reason, a.created_at,
                   u.email as requester_email, u.name as requester_name
            FROM approvals a
            JOIN users u ON a.user_id = u.id
            WHERE a.status = 'pending'
            ORDER BY a.created_at ASC
        """)
        
        return JSONResponse({
            "approvals": [
                {
                    "id": str(r["id"]),
                    "session_id": str(r["session_id"]),
                    "tool_name": r["tool_name"],
                    "tool_args": json.loads(r["tool_args"]),
                    "reason": r["reason"],
                    "created_at": r["created_at"].isoformat(),
                    "requester": {
                        "email": r["requester_email"],
                        "name": r["requester_name"]
                    }
                }
                for r in rows
            ]
        })
    finally:
        await conn.close()