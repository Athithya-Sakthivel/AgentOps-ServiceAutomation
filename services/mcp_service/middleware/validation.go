package middleware

import (
	"github.com/gofiber/fiber/v2"
)

func RequireJSON() fiber.Handler {
	return func(c *fiber.Ctx) error {
		if c.Method() == fiber.MethodPost || c.Method() == fiber.MethodPut || c.Method() == fiber.MethodPatch {
			ct := string(c.Request().Header.ContentType())
			if ct != "application/json" && ct != "application/json; charset=utf-8" {
				return c.Status(fiber.StatusUnsupportedMediaType).JSON(fiber.Map{
					"error": "unsupported media type; use application/json",
				})
			}
		}
		return c.Next()
	}
}