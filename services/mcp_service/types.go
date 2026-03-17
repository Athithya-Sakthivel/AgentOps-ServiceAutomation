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