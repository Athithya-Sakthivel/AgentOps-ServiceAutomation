package middleware

import "github.com/gofiber/fiber/v2"

const IdempotencyHeader = "Idempotency-Key"

func IdempotencyKey() fiber.Handler {
	return func(c *fiber.Ctx) error {
		key := c.Get(IdempotencyHeader)
		c.Locals("idempotency_key", key)
		return c.Next()
	}
}