package main

import (
	"context"
	"database/sql"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "github.com/golang-migrate/migrate/v4/source/file"
	_ "github.com/jackc/pgx/v5/stdlib"

	migratepg "github.com/golang-migrate/migrate/v4/database/postgres"
	"github.com/golang-migrate/migrate/v4"

	"github.com/Athithya-Sakthivel/AgentOps-ServiceAutomation/services/mcp_service"
	dbpkg "github.com/Athithya-Sakthivel/AgentOps-ServiceAutomation/services/mcp_service/db"
	"github.com/Athithya-Sakthivel/AgentOps-ServiceAutomation/services/mcp_service/middleware"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"
)

func main() {
	logger, _ := zap.NewProduction()
	defer logger.Sync()

	ctx := context.Background()

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		logger.Fatal("DATABASE_URL environment variable is required")
	}

	addr := os.Getenv("MCP_ADDR")
	if addr == "" {
		addr = ":8080"
	}

	migrationsDir := os.Getenv("MIGRATIONS_DIR")
	if migrationsDir == "" {
		migrationsDir = "file://./migrations"
	}

	applyMigrations := true
	if v := os.Getenv("MIGRATE_ON_START"); v == "false" || v == "0" {
		applyMigrations = false
	}

	if applyMigrations {
		logger.Info("applying migrations", zap.String("dir", migrationsDir))
		if err := applyMigrationsSQL(databaseURL, migrationsDir); err != nil {
			logger.Fatal("migrations failed", zap.Error(err))
		}
		logger.Info("migrations applied")
	}

	pool, err := initPool(ctx, databaseURL, logger)
	if err != nil {
		logger.Fatal("pgx pool init failed", zap.Error(err))
	}

	db := dbpkg.NewDB(ctx, pool, logger)
	server := mcp_service.NewServer(logger, db)

	server.App.Use(middleware.IdempotencyKey())
	server.App.Use(middleware.RequestLogger(logger))
	server.App.Use(middleware.RequireJSON())

	go func() {
		if err := server.Start(addr); err != nil {
			logger.Fatal("server listen failed", zap.Error(err))
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		logger.Error("server shutdown error", zap.Error(err))
	} else {
		logger.Info("server shutdown complete")
	}
}

func applyMigrationsSQL(databaseURL, migrationsDir string) error {
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

func initPool(ctx context.Context, databaseURL string, logger *zap.Logger) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		logger.Error("pgxpool.ParseConfig failed", zap.Error(err))
		return nil, err
	}
	if cfg.MaxConns == 0 {
		cfg.MaxConns = 8
	}
	if cfg.MinConns == 0 {
		cfg.MinConns = 1
	}
	cfg.MaxConnIdleTime = 5 * time.Minute

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		logger.Error("pgxpool.NewWithConfig failed", zap.Error(err))
		return nil, err
	}

	pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, err
	}
	logger.Info("pgxpool connected")
	return pool, nil
}