package mcp_service

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/jackc/pgconn"
	"github.com/oklog/ulid/v2"
	"go.uber.org/zap"
)

type Server struct {
	Logger *zap.Logger
	DB     *DB
	App    *fiber.App
}

func NewServer(ctx context.Context, logger *zap.Logger, db *DB) *Server {
	app := fiber.New(fiber.Config{
		DisableStartupMessage: true,
	})

	s := &Server{
		Logger: logger,
		DB:     db,
		App:    app,
	}

	app.Get("/health", s.handleHealth)
	app.Post("/tools/:name", s.handleToolCall)

	return s
}

func (s *Server) Start(addr string) error {
	s.Logger.Info("starting mcp_service", zap.String("addr", addr))
	return s.App.Listen(addr)
}

func (s *Server) Shutdown(ctx context.Context) error {
	s.Logger.Info("shutting down server")
	_ = s.App.Shutdown()
	s.DB.Close()
	return nil
}

func (s *Server) handleHealth(c *fiber.Ctx) error {
	return c.Status(fiber.StatusOK).JSON(fiber.Map{
		"status": "ok",
		"time":   time.Now().UTC().Format(time.RFC3339),
	})
}

func (s *Server) handleToolCall(c *fiber.Ctx) error {
	toolName := c.Params("name")
	var req ToolRequest
	if err := c.BodyParser(&req); err != nil {
		s.Logger.Warn("invalid body", zap.Error(err))
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{"error": "invalid JSON"})
	}

	entropy := rand.Reader
	id, err := ulid.New(ulid.Timestamp(time.Now()), entropy)
	if err != nil {
		s.Logger.Error("ulid generation failed", zap.Error(err))
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{"error": "internal"})
	}
	ulidStr := id.String()

	reqBytes, _ := json.Marshal(req)
	idempotencyKey, _ := c.Locals("idempotency_key").(string)
	ctx := c.Context()

	// Insert a new tool_calls row and return the DB-generated UUID.
	var toolCallID string
	err = s.DB.Pool.QueryRow(ctx,
		`INSERT INTO tool_calls (tool_name, idempotency_key, request_payload, status, created_at)
         VALUES ($1,$2,$3,$4,$5) RETURNING tool_call_id`,
		toolName, nullEmpty(idempotencyKey), json.RawMessage(reqBytes), "accepted", time.Now().UTC(),
	).Scan(&toolCallID)

	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" && idempotencyKey != "" {
			// idempotent case: fetch existing record and return its response_payload if present
			var existingID string
			var respPayload json.RawMessage
			row := s.DB.Pool.QueryRow(ctx,
				`SELECT tool_call_id, response_payload FROM tool_calls WHERE tool_name=$1 AND idempotency_key=$2 LIMIT 1`,
				toolName, idempotencyKey)
			if rerr := row.Scan(&existingID, &respPayload); rerr == nil {
				s.Logger.Info("idempotent request detected", zap.String("tool_call_id", existingID), zap.String("tool", toolName))
				if len(respPayload) > 0 {
					var tr ToolResponse
					_ = json.Unmarshal(respPayload, &tr)
					return c.Status(fiber.StatusOK).JSON(tr)
				}
				return c.Status(fiber.StatusAccepted).JSON(fiber.Map{"status": "accepted", "tool_call_id": existingID})
			}
		}
		s.Logger.Error("insert tool_calls failed", zap.Error(err), zap.String("tool", toolName))
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{"error": "db error"})
	}

	// Prepare response and update the tool_calls row with response_payload and final status.
	resp := ToolResponse{
		Status: "accepted",
		Result: json.RawMessage(`{"tool_call_id":"` + toolCallID + `","ulid":"` + ulidStr + `"}`),
	}
	respBytes, _ := json.Marshal(resp)

	if _, err := s.DB.Pool.Exec(ctx, `UPDATE tool_calls SET response_payload=$1, status=$2 WHERE tool_call_id=$3`, json.RawMessage(respBytes), "success", toolCallID); err != nil {
		s.Logger.Error("update tool_calls response failed", zap.Error(err), zap.String("tool_call_id", toolCallID))
		// do not fail the client if audit update fails; return accepted but log error
		return c.Status(fiber.StatusAccepted).JSON(resp)
	}

	return c.Status(fiber.StatusAccepted).JSON(resp)
}

func nullEmpty(s string) interface{} {
	if s == "" {
		return nil
	}
	return s
}