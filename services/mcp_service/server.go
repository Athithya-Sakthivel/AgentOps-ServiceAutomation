package mcp_service

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"time"

	dbpkg "github.com/Athithya-Sakthivel/AgentOps-ServiceAutomation/services/mcp_service/db"
	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/fiber/v2/middleware/limiter"
	"github.com/oklog/ulid/v2"
	"go.uber.org/zap"
)

type Server struct {
	Logger *zap.Logger
	DB     *dbpkg.DB
	App    *fiber.App
}

func NewServer(logger *zap.Logger, db *dbpkg.DB) *Server {
	app := fiber.New(fiber.Config{
		DisableStartupMessage: true,
		ReadTimeout:           10 * time.Second,
		WriteTimeout:          10 * time.Second,
		IdleTimeout:           60 * time.Second,
		BodyLimit:             256 * 1024, // 256KB
	})

	app.Use(limiter.New(limiter.Config{
		Max:        200,
		Expiration: 1 * time.Minute,
	}))

	s := &Server{
		Logger: logger,
		DB:     db,
		App:    app,
	}

	app.Get("/health", s.handleHealth)
	app.Get("/ready", s.handleReady)
	app.Post("/tools/:name", s.handleToolCall)

	return s
}

func (s *Server) Start(addr string) error {
	s.Logger.Info("starting mcp_service", zap.String("addr", addr))
	return s.App.Listen(addr)
}

func (s *Server) Shutdown(ctx context.Context) error {
	s.Logger.Info("shutting down mcp_service")
	_ = s.App.Shutdown()
	s.DB.Close()
	return nil
}

func (s *Server) handleHealth(c *fiber.Ctx) error {
	return c.Status(http.StatusOK).JSON(fiber.Map{"status": "ok"})
}

func (s *Server) handleReady(c *fiber.Ctx) error {
	ctx := c.UserContext()
	if err := s.DB.Ping(ctx); err != nil {
		s.Logger.Error("readiness check failed", zap.Error(err))
		return c.Status(http.StatusServiceUnavailable).JSON(fiber.Map{"ready": false})
	}
	return c.Status(http.StatusOK).JSON(fiber.Map{"ready": true})
}

func (s *Server) handleToolCall(c *fiber.Ctx) error {
	toolName := c.Params("name")
	if toolName == "" {
		return c.Status(http.StatusBadRequest).JSON(fiber.Map{"error": "tool name required"})
	}

	ctx := c.UserContext()

	var req ToolRequest
	if err := c.BodyParser(&req); err != nil {
		s.Logger.Warn("invalid request body", zap.Error(err))
		return c.Status(http.StatusBadRequest).JSON(fiber.Map{"error": "invalid JSON body"})
	}

	// optional idempotency
	var idempPtr *string
	if v := c.Locals("idempotency_key"); v != nil {
		if ks, ok := v.(string); ok && ks != "" {
			idempPtr = &ks
		}
	}

	reqBytes, _ := json.Marshal(req)

	toolCallID, err := s.DB.InsertToolCall(ctx, toolName, idempPtr, reqBytes)
	if err != nil {
		// handle unique violation case
		if dbpkg.IsUniqueViolation(err) && idempPtr != nil {
			existingID, respBytes, getErr := s.DB.GetToolCallByToolAndIdempotency(ctx, toolName, *idempPtr)
			if getErr == nil {
				s.Logger.Info("idempotent collision - returning existing", zap.String("tool_call_id", existingID), zap.String("tool", toolName))
				if len(respBytes) > 0 {
					var tr ToolResponse
					if uerr := json.Unmarshal(respBytes, &tr); uerr == nil {
						return c.Status(http.StatusOK).JSON(tr)
					}
				}
				return c.Status(http.StatusAccepted).JSON(fiber.Map{"status": "accepted", "tool_call_id": existingID})
			}
		}
		s.Logger.Error("insert tool_calls failed", zap.Error(err), zap.String("tool", toolName))
		return c.Status(http.StatusInternalServerError).JSON(fiber.Map{"error": "db insert failed"})
	}

	entropy := rand.Reader
	ul, _ := ulid.New(ulid.Timestamp(time.Now()), entropy)
	resp := ToolResponse{
		Status: "accepted",
		Result: json.RawMessage([]byte(`{"tool_call_id":"` + toolCallID + `","ulid":"` + ul.String() + `"}`)),
	}
	respBytes, _ := json.Marshal(resp)

	if uerr := s.DB.UpdateToolCallResponse(ctx, toolCallID, respBytes, "success"); uerr != nil {
		s.Logger.Error("failed to update tool_call response", zap.Error(uerr), zap.String("tool_call_id", toolCallID))
		return c.Status(http.StatusAccepted).JSON(resp)
	}

	return c.Status(http.StatusAccepted).JSON(resp)
}