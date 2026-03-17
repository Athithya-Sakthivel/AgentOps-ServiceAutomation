package middleware

import (
	"time"

	"github.com/gofiber/fiber/v2"
	"go.uber.org/zap"
)

func RequestLogger(logger *zap.Logger) fiber.Handler {
	return func(c *fiber.Ctx) error {
		start := time.Now()
		err := c.Next()
		lat := time.Since(start)
		idemp, _ := c.Locals("idempotency_key").(string)
		logger.Info("http.request",
			zap.String("method", string(c.Method())),
			zap.String("path", c.OriginalURL()),
			zap.Int("status", c.Response().StatusCode()),
			zap.Duration("latency", lat),
			zap.String("idempotency_key", idemp),
		)
		return err
	}
}