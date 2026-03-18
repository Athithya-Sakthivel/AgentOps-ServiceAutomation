package mcp_service

import "encoding/json"

type ToolRequest struct {
	Params json.RawMessage `json:"params"`
	Meta   json.RawMessage `json:"meta,omitempty"`
}

type ToolResponse struct {
	Status string          `json:"status"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  string          `json:"error,omitempty"`
}

type ToolCallRecord struct {
	ToolCallID      string          `json:"tool_call_id"`
	RunID           *string         `json:"run_id,omitempty"`
	ToolName        string          `json:"tool_name"`
	IdempotencyKey  *string         `json:"idempotency_key,omitempty"`
	RequestPayload  json.RawMessage `json:"request_payload"`
	ResponsePayload json.RawMessage `json:"response_payload,omitempty"`
	Status          string          `json:"status"`
	CreatedAt       string          `json:"created_at"`
}