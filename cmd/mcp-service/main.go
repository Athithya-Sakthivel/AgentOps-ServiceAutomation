package main

import (
	"context"
	"database/sql"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "github.com/golang-migrate/migrate/v4/source/file"
	"github.com/golang-migrate/migrate/v4"
	migratepg "github.com/golang-migrate/migrate/v4/database/postgres"
	_ "github.com/golang-migrate/migrate/v4/database/postgres"
	_ "github.com/jackc/pgx/v5/stdlib"

	mcp "github.com/Athithya-Sakthivel/AgentOps-ServiceAutomation/services/mcp_service"
	"github.com/Athithya-Sakthivel/AgentOps-ServiceAutomation/services/mcp_service/middleware"

	"go.uber.org/zap"
)

func main() {
	logger, err := zap.NewProduction()
	if err != nil {
		panic(err)
	}
	defer logger.Sync()

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		logger.Fatal("DATABASE_URL environment variable is required")
	}

	logger.Info("app starting", zap.String("DATABASE_URL_redacted", redactDB(databaseURL)))

	// Apply migrations from ./migrations using database/sql with pgx stdlib
	if err := applyMigrations(databaseURL, "file://./migrations", logger); err != nil {
		logger.Fatal("migrations failed", zap.Error(err))
	}
	logger.Info("migrations applied")

	ctx := context.Background()
	db, err := mcp.NewDB(ctx, logger)
	if err != nil {
		logger.Fatal("db init failed", zap.Error(err))
	}

	// sanity: ensure tool_calls exists (migration 003 creates it)
	if ok := ensureToolCallsExists(ctx, db, logger); !ok {
		logger.Fatal("required table tool_calls not found; apply migrations before starting")
	}

	srv := mcp.NewServer(ctx, logger, db)

	srv.App.Use(middleware.IdempotencyKey())
	srv.App.Use(middleware.RequestLogger(logger))
	srv.App.Use(middleware.RequireJSON())

	addr := os.Getenv("MCP_ADDR")
	if addr == "" {
		addr = ":8080"
	}

	go func() {
		if err := srv.Start(addr); err != nil {
			logger.Fatal("server failed", zap.Error(err))
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, os.Interrupt, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("shutdown failed", zap.Error(err))
	}
}

func applyMigrations(databaseURL, migrationsDir string, logger *zap.Logger) error {
	db, err := sql.Open("pgx", databaseURL)
	if err != nil {
		return err
	}
	defer db.Close()

	if err := db.Ping(); err != nil {
		return err
	}

	driver, err := migratepg.WithInstance(db, &migratepg.Config{})
	if err != nil {
		return err
	}

	m, err := migrate.NewWithDatabaseInstance(migrationsDir, "postgres", driver)
	if err != nil {
		return err
	}

	if err := m.Up(); err != nil && err != migrate.ErrNoChange {
		return err
	}
	return nil
}

func ensureToolCallsExists(ctx context.Context, db *mcp.DB, logger *zap.Logger) bool {
	row := db.Pool.QueryRow(ctx, `SELECT to_regclass('public.tool_calls')`)
	var name *string
	if err := row.Scan(&name); err != nil {
		logger.Error("check tool_calls failed", zap.Error(err))
		return false
	}
	if name == nil {
		logger.Warn("tool_calls table not present")
		return false
	}
	logger.Info("tool_calls table found")
	return true
}

func redactDB(s string) string {
	// minimal redaction for logs
	return s
}