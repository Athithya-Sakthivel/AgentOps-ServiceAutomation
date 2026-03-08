import os
import sys
import json
import time
import logging
from typing import TypedDict, List, Dict, Any, Optional, Literal
from jsonschema import validate, ValidationError as SchemaValidationError
from langgraph.graph import StateGraph, END
from langgraph.checkpoint.postgres import PostgresSaver
import asyncpg
from ray import serve

logging.basicConfig(
    level=getattr(logging, os.getenv("LOG_LEVEL", "INFO").upper()),
    format='{"time":"%(asctime)s","level":"%(levelname)s","message":"%(message)s","logger":"%(name)s"}',
    datefmt="%Y-%m-%dT%H:%M:%S%z"
)
logger = logging.getLogger("agents")

DATABASE_URL = os.getenv("DATABASE_URL")
if not DATABASE_URL:
    logger.error("DATABASE_URL environment variable required")
    sys.exit(1)

APPROVAL_THRESHOLD = float(os.getenv("APPROVAL_THRESHOLD", "100.0"))

class AgentState(TypedDict):
    session_id: str
    user_id: str
    messages: List[Dict[str, Any]]
    current_tool: Optional[str]
    tool_args: Optional[Dict[str, Any]]
    tool_result: Optional[Dict[str, Any]]
    approval_required: bool
    approval_status: Optional[Literal["pending", "approved", "rejected"]]
    approval_reason: Optional[str]
    error: Optional[str]
    completed: bool

class MCPTool:
    def __init__(self, name: str, description: str, input_schema: Dict[str, Any], execution_fn):
        self.name = name
        self.description = description
        self.input_schema = input_schema
        self.execute = execution_fn
    
    def to_openai_tool(self) -> Dict[str, Any]:
        return {
            "type": "function",
            "function": {
                "name": self.name,
                "description": self.description,
                "parameters": self.input_schema
            }
        }

async def _call_external_api(endpoint: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    from httpx import AsyncClient
    async with AsyncClient(timeout=10.0) as client:
        resp = await client.post(f"http://external-api:9000{endpoint}", json=payload)
        resp.raise_for_status()
        return resp.json()

async def execute_get_order_status(args: Dict[str, Any]) -> Dict[str, Any]:
    result = await _call_external_api("/orders/status", {"order_id": args["order_id"]})
    return {
        "success": True,
        "order_id": args["order_id"],
        "status": result.get("status", "unknown"),
        "items": result.get("items", []),
        "shipping": result.get("shipping", {})
    }

async def execute_process_refund(args: Dict[str, Any]) -> Dict[str, Any]:
    amount = args["amount"]
    if amount > APPROVAL_THRESHOLD:
        return {
            "approval_required": True,
            "amount": amount,
            "threshold": APPROVAL_THRESHOLD,
            "message": f"Refund of ${amount:.2f} requires manager approval (threshold: ${APPROVAL_THRESHOLD:.2f})"
        }
    
    result = await _call_external_api("/orders/refund", args)
    return {
        "success": True,
        "refund_id": result.get("refund_id"),
        "amount": amount,
        "status": "processed"
    }

async def execute_escalate_to_human(args: Dict[str, Any]) -> Dict[str, Any]:
    result = await _call_external_api("/support/tickets", args)
    return {
        "success": True,
        "ticket_id": result.get("ticket_id"),
        "priority": args.get("priority", "medium")
    }

async def execute_update_customer_note(args: Dict[str, Any]) -> Dict[str, Any]:
    return {"success": True, "note_added": True}

TOOLS = [
    MCPTool(
        name="get_order_status",
        description="Retrieve current status, items, and shipping details for a customer order",
        input_schema={
            "type": "object",
            "properties": {
                "order_id": {"type": "string", "description": "Alphanumeric order ID (e.g., ORD-12345)"}
            },
            "required": ["order_id"],
            "additionalProperties": False
        },
        execution_fn=execute_get_order_status
    ),
    MCPTool(
        name="process_refund",
        description="Initiate a refund for a completed order. Amounts over $100 require manager approval.",
        input_schema={
            "type": "object",
            "properties": {
                "order_id": {"type": "string", "description": "Alphanumeric order ID"},
                "amount": {"type": "number", "minimum": 0.01, "description": "Refund amount in USD"},
                "reason": {"type": "string", "minLength": 5, "maxLength": 500, "description": "Reason for refund"}
            },
            "required": ["order_id", "amount", "reason"],
            "additionalProperties": False
        },
        execution_fn=execute_process_refund
    ),
    MCPTool(
        name="escalate_to_human",
        description="Create a support ticket for complex issues requiring human agent",
        input_schema={
            "type": "object",
            "properties": {
                "issue_description": {"type": "string", "minLength": 10, "maxLength": 2000, "description": "Detailed description of issue"},
                "priority": {"type": "string", "enum": ["low", "medium", "high", "critical"], "default": "medium", "description": "Support ticket priority"}
            },
            "required": ["issue_description"],
            "additionalProperties": False
        },
        execution_fn=execute_escalate_to_human
    ),
    MCPTool(
        name="update_customer_note",
        description="Append a note to the customer's service history for future reference",
        input_schema={
            "type": "object",
            "properties": {
                "note": {"type": "string", "minLength": 5, "maxLength": 1000, "description": "Customer service note"}
            },
            "required": ["note"],
            "additionalProperties": False
        },
        execution_fn=execute_update_customer_note
    )
]

TOOL_REGISTRY = {tool.name: tool for tool in TOOLS}

async def _audit_log(user_id: str, session_id: str, action: str, details: Dict[str, Any]):
    conn = await asyncpg.connect(DATABASE_URL)
    try:
        await conn.execute("""
            INSERT INTO audit_logs (user_id, session_id, action, details)
            VALUES ($1, $2, $3, $4)
        """, user_id if user_id != "anonymous" else None, session_id, action, json.dumps(details))
    finally:
        await conn.close()

async def load_state(state: AgentState) -> AgentState:
    logger.info(f"state.load.start session_id={state['session_id']}")
    return state

async def plan_action(state: AgentState) -> AgentState:
    handle = serve.get_app_handle("llm_app")
    
    messages = [
        {"role": "system", "content": "You are a helpful customer service assistant. Use tools to fulfill user requests. Only call tools when necessary."},
        *state["messages"]
    ]
    
    tools = [tool.to_openai_tool() for tool in TOOLS]
    
    request_id = f"plan_{int(time.time()*1000)}_{os.urandom(4).hex()}"
    result = await handle.remote({
        "request_id": request_id,
        "messages": messages,
        "tools": tools,
        "max_tokens": 512,
        "temperature": 0.1,
        "seed": 42
    })
    
    if not result.get("success"):
        state["error"] = f"Planning failed: {result.get('error', 'unknown')}"
        state["completed"] = True
        logger.error(f"planning.failed session_id={state['session_id']} error={state['error']}")
        return state
    
    tool_calls = result.get("tool_calls")
    if tool_calls:
        call = tool_calls[0]["function"]
        tool_name = call["name"]
        try:
            args = json.loads(call["arguments"])
            schema = TOOL_REGISTRY[tool_name].input_schema
            validate(instance=args, schema=schema)
            state["current_tool"] = tool_name
            state["tool_args"] = args
            logger.info(f"tool.selected session_id={state['session_id']} tool={tool_name} args_keys={list(args.keys())}")
        except (json.JSONDecodeError, SchemaValidationError, KeyError) as e:
            state["error"] = f"Invalid tool arguments for {tool_name}: {str(e)}"
            state["completed"] = True
            logger.warning(f"tool.validation.failed session_id={state['session_id']} tool={tool_name} error={str(e)}")
    else:
        content = result.get("content", "").strip()
        if content:
            state["messages"].append({"role": "assistant", "content": content})
            state["completed"] = True
            logger.info(f"direct.response session_id={state['session_id']} content_preview={content[:100]}")
    
    return state

async def execute_tool(state: AgentState) -> AgentState:
    if state.get("error") or state.get("completed") or not state.get("current_tool"):
        return state
    
    tool_name = state["current_tool"]
    tool_args = state["tool_args"] or {}
    tool = TOOL_REGISTRY.get(tool_name)
    
    if not tool:
        state["error"] = f"Unknown tool: {tool_name}"
        state["completed"] = True
        logger.error(f"tool.unknown session_id={state['session_id']} tool={tool_name}")
        return state
    
    try:
        result = await tool.execute(tool_args)
        
        if result.get("approval_required"):
            state["approval_required"] = True
            state["approval_reason"] = result["message"]
            state["tool_result"] = result
            logger.info(f"approval.required session_id={state['session_id']} tool={tool_name} amount={result.get('amount')}")
            return state
        
        state["tool_result"] = result
        
        if result.get("success"):
            await _audit_log(
                state["user_id"],
                state["session_id"],
                f"tool_executed_{tool_name}",
                {"tool": tool_name, "args": tool_args, "result": result}
            )
            logger.info(f"tool.executed.success session_id={state['session_id']} tool={tool_name}")
        else:
            state["error"] = f"Tool execution failed: {result}"
            state["completed"] = True
            logger.error(f"tool.execution.failed session_id={state['session_id']} tool={tool_name} result={result}")
    
    except Exception as e:
        state["error"] = f"Tool execution error: {str(e)}"
        state["completed"] = True
        logger.exception(f"tool.execution.exception session_id={state['session_id']} tool={tool_name} error={str(e)}")
    
    return state

async def check_approval(state: AgentState) -> Literal["approval_gate", "generate_response"]:
    if state.get("approval_required") and not state.get("approval_status"):
        return "approval_gate"
    return "generate_response"

async def approval_gate(state: AgentState) -> AgentState:
    conn = await asyncpg.connect(DATABASE_URL)
    try:
        await conn.execute("""
            INSERT INTO approvals (session_id, user_id, tool_name, tool_args, reason, status)
            VALUES ($1, $2, $3, $4, $5, 'pending')
        """, 
            state["session_id"],
            state["user_id"],
            state["current_tool"],
            json.dumps(state["tool_args"]),
            state["approval_reason"]
        )
        logger.info(f"approval.requested session_id={state['session_id']} tool={state['current_tool']}")
    finally:
        await conn.close()
    
    state["messages"].append({
        "role": "assistant",
        "content": state["tool_result"]["message"]
    })
    state["completed"] = True
    return state

async def generate_response(state: AgentState) -> AgentState:
    if state.get("error"):
        response = f"❌ Error: {state['error']}"
    elif state.get("tool_result"):
        result = state["tool_result"]
        tool_name = state["current_tool"]
        
        if tool_name == "get_order_status":
            items = "\n".join([f"  • {i['name']}: ${i['price']:.2f}" for i in result.get("items", [])])
            response = f"📦 Order {result['order_id']} status: {result['status']}\nItems:\n{items}\nShipping: {result.get('shipping', {}).get('status', 'N/A')}"
        elif tool_name == "process_refund":
            response = f"✅ Refund of ${result['amount']:.2f} processed successfully (ID: {result['refund_id']})"
        elif tool_name == "escalate_to_human":
            response = f"🎫 Support ticket created (ID: {result['ticket_id']}) with {result['priority']} priority. An agent will contact you shortly."
        elif tool_name == "update_customer_note":
            response = "✅ Note added to your account."
        else:
            response = "✅ Request completed successfully."
    else:
        response = "I've processed your request. How else can I help?"
    
    state["messages"].append({"role": "assistant", "content": response})
    state["completed"] = True
    
    logger.info(f"response.generated session_id={state['session_id']} tool={state.get('current_tool')} preview={response[:100]}")
    return state

async def persist_state(state: AgentState) -> AgentState:
    logger.info(f"state.persist session_id={state['session_id']} completed={state['completed']}")
    return state

def create_graph(checkpointer: PostgresSaver):
    workflow = StateGraph(AgentState)
    
    workflow.add_node("load_state", load_state)
    workflow.add_node("plan_action", plan_action)
    workflow.add_node("execute_tool", execute_tool)
    workflow.add_node("approval_gate", approval_gate)
    workflow.add_node("generate_response", generate_response)
    workflow.add_node("persist_state", persist_state)
    
    workflow.set_entry_point("load_state")
    workflow.add_edge("load_state", "plan_action")
    workflow.add_edge("plan_action", "execute_tool")
    workflow.add_conditional_edges("execute_tool", check_approval, {
        "approval_gate": "approval_gate",
        "generate_response": "generate_response"
    })
    workflow.add_edge("approval_gate", "persist_state")
    workflow.add_edge("generate_response", "persist_state")
    workflow.add_edge("persist_state", END)
    
    return workflow.compile(checkpointer=checkpointer)