// File: cmd/bootstrap-demo-users/main.go
package main

// Idempotent seeder for Postgres "agents" DB.
// - zap for structured logging
// - gofakeit v7 deterministic fake data
// - oklog/ulid v2 deterministic ULIDs
// - jackc/pgx v5 pgxpool for DB pooling
//
// Usage:
//   go build -o bootstrap-demo-users ./cmd/bootstrap-demo-users
//   SEED=2026 ./bootstrap-demo-users
//
// Requirements:
// - kubectl configured and secret `postgres-cluster-app` in namespace `default`
// - Postgres pooler service named `postgres-pooler` in same namespace
//
// The seeder creates three tables: users, subscriptions, payments and seeds deterministic data.

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	mrand "math/rand"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/brianvoe/gofakeit/v7"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/oklog/ulid/v2"
	"go.uber.org/zap"
)

const (
	k8sSecretName  = "postgres-cluster-app"
	k8sNamespace   = "default"
	poolerService  = "postgres-pooler"
	poolerPort     = 5432
	targetDB       = "agents"
	connectTimeout = 5 // seconds
)

// runCmd runs a command with context and returns combined stdout+stderr.
func runCmd(ctx context.Context, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	out, err := cmd.CombinedOutput()
	outStr := strings.TrimSpace(string(out))
	if err != nil {
		return outStr, fmt.Errorf("command %s %v failed: %w; output: %s", name, args, err, outStr)
	}
	return outStr, nil
}

// k8sSecretField fetches and base64-decodes a field from a k8s secret using kubectl.
func k8sSecretField(ctx context.Context, secret, namespace, field string) (string, error) {
	out, err := runCmd(ctx, "kubectl", "get", "secret", secret, "-n", namespace, "-o", fmt.Sprintf("jsonpath={.data.%s}", field))
	if err != nil {
		return "", fmt.Errorf("kubectl get secret failed: %w", err)
	}
	if out == "" {
		return "", fmt.Errorf("secret %s field %s empty", secret, field)
	}
	decoded, derr := base64.StdEncoding.DecodeString(out)
	if derr != nil {
		return "", fmt.Errorf("failed to decode secret field %s: %w", field, derr)
	}
	return string(decoded), nil
}

func svcDNSName(svc, namespace string) string {
	return fmt.Sprintf("%s.%s.svc.cluster.local", svc, namespace)
}

func svcResolvable(host string) bool {
	_, err := net.LookupHost(host)
	return err == nil
}

// waitForPort tests TCP connect on host:port until timeout.
func waitForPort(host string, port int, timeout time.Duration) bool {
	address := fmt.Sprintf("%s:%d", host, port)
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", address, 2*time.Second)
		if err == nil {
			_ = conn.Close()
			return true
		}
		time.Sleep(300 * time.Millisecond)
	}
	return false
}

// startPortForward starts kubectl port-forward and returns the process for cleanup.
func startPortForward(ctx context.Context, namespace, svc string, localPort, remotePort int, logger *zap.SugaredLogger) (*exec.Cmd, error) {
	args := []string{"port-forward", fmt.Sprintf("svc/%s", svc), fmt.Sprintf("%d:%d", localPort, remotePort), "-n", namespace}
	cmd := exec.CommandContext(ctx, "kubectl", args...)
	// create new process group so we can kill whole group
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// stream kubectl output to current process for easier debugging
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start port-forward: %w", err)
	}
	// wait until bind
	if !waitForPort("127.0.0.1", localPort, 25*time.Second) {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		return nil, fmt.Errorf("port-forward failed to bind localhost:%d", localPort)
	}
	logger.Infof("port-forward ready on localhost:%d (pid=%d)", localPort, cmd.Process.Pid)
	return cmd, nil
}

// stopPortForward kills the kubectl port-forward process group.
func stopPortForward(cmd *exec.Cmd, logger *zap.SugaredLogger) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	pid := cmd.Process.Pid
	logger.Infof("stopping port-forward (pid=%d)", pid)
	_ = syscall.Kill(-pid, syscall.SIGTERM)
	_ = cmd.Process.Kill()
	_, _ = cmd.Process.Wait()
}

// urlEscape escapes a few characters for libpq URL usage.
func urlEscape(s string) string {
	r := strings.NewReplacer(" ", "%20", "@", "%40", ":", "%3A", "/", "%2F")
	return r.Replace(s)
}

// makeConnURL constructs a libpq-style postgresql URL with connect_timeout.
func makeConnURL(user, password, host string, port int, db string, connectTimeoutSeconds int) string {
	qt := fmt.Sprintf("connect_timeout=%d", connectTimeoutSeconds)
	return fmt.Sprintf("postgresql://%s:%s@%s:%d/%s?%s&application_name=bootstrap_demo_users",
		urlEscape(user), urlEscape(password), host, port, db, qt)
}

// tryConnect attempts to create a pgxpool and Ping until maxWait.
func tryConnect(ctx context.Context, connURL string, maxWait time.Duration, logger *zap.SugaredLogger) (*pgxpool.Pool, error) {
	deadline := time.Now().Add(maxWait)
	var lastErr error
	for time.Now().Before(deadline) {
		cfg, err := pgxpool.ParseConfig(connURL)
		if err != nil {
			return nil, fmt.Errorf("pgxpool parse config failed: %w", err)
		}
		// sane defaults
		if cfg.MaxConns == 0 {
			cfg.MaxConns = 8
		}
		pool, err := pgxpool.NewWithConfig(ctx, cfg)
		if err == nil {
			pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
			err = pool.Ping(pingCtx)
			cancel()
			if err == nil {
				logger.Infof("connected to database")
				return pool, nil
			}
			// close pool before retrying
			pool.Close()
		}
		lastErr = err
		logger.Warnf("connect attempt failed: %v; retrying", err)
		time.Sleep(1 * time.Second)
	}
	return nil, fmt.Errorf("unable to connect within %s: last error: %w", maxWait.String(), lastErr)
}

// ensureTables creates users, subscriptions, payments tables if they don't exist.
func ensureTables(ctx context.Context, pool *pgxpool.Pool, logger *zap.SugaredLogger) error {
	sql := `
CREATE TABLE IF NOT EXISTS users (
  user_id TEXT PRIMARY KEY,
  email TEXT UNIQUE NOT NULL,
  name TEXT NOT NULL,
  account_status TEXT NOT NULL CHECK (account_status IN ('active','past_due','cancelled')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);

CREATE TABLE IF NOT EXISTS subscriptions (
  subscription_id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  plan TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('active','past_due','cancelled')),
  renewal_date TIMESTAMPTZ,
  billing_cycle_anchor TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_user ON subscriptions(user_id);

CREATE TABLE IF NOT EXISTS payments (
  payment_id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  amount_cents INTEGER NOT NULL,
  currency TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('succeeded','failed','refunded')),
  created_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_payments_user_created ON payments(user_id, created_at DESC);
`
	ctxExec, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	_, err := pool.Exec(ctxExec, sql)
	if err != nil {
		return fmt.Errorf("ensureTables exec failed: %w", err)
	}
	logger.Info("ensured tables exist")
	return nil
}

// newULIDDet generates a deterministic ULID string using a fixed base time and seed+index entropy.
func newULIDDet(seedVal int64, idx int) (string, error) {
	// choose a stable base time for deterministic ordering
	base := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	// offset ms per index to avoid collisions at same ms
	msTime := base.Add(time.Duration(idx) * time.Millisecond)
	ts := ulid.Timestamp(msTime)

	// math/rand.Rand used as entropy source; it implements Read
	src := mrand.New(mrand.NewSource(seedVal + int64(idx)))
	id, err := ulid.New(ts, src)
	if err != nil {
		return "", err
	}
	return id.String(), nil
}

// seedUsers inserts deterministic users using gofakeit seeded with seedVal.
func seedUsers(ctx context.Context, pool *pgxpool.Pool, n int, seedVal int64, logger *zap.SugaredLogger) ([]struct {
	UserID string
	Email  string
}, error) {
	if n <= 0 {
		return nil, errors.New("n must be > 0")
	}
	// gofakeit.Seed accepts variadic args; passing seedVal yields deterministic output.
	// When seedVal == 0, gofakeit will use crypto/rand internally.
	gofakeit.Seed(uint64(seedVal))

	txCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	tx, err := pool.Begin(txCtx)
	if err != nil {
		return nil, fmt.Errorf("begin tx failed: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	insertSQL := `INSERT INTO users (user_id, email, name, account_status, created_at) VALUES ($1,$2,$3,$4,$5) ON CONFLICT (email) DO NOTHING;`

	out := make([]struct {
		UserID string
		Email  string
	}, 0, n)

	for i := 0; i < n; i++ {
		uid, err := newULIDDet(seedVal, i+1)
		if err != nil {
			logger.Errorf("ulid generation failed: %v", err)
			return nil, fmt.Errorf("ulid generation: %w", err)
		}
		name := gofakeit.Name()
		username := gofakeit.Username()
		// sanitize username to be email-local friendly
		username = strings.ToLower(strings.Map(func(r rune) rune {
			if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '.' || r == '_' || r == '-' {
				return r
			}
			return -1
		}, username))
		email := fmt.Sprintf("%s%d@demo.local", username, i+1)
		status := "active"
		if i%17 == 0 {
			status = "past_due"
		} else if i%31 == 0 {
			status = "cancelled"
		}
		createdAt := time.Now().UTC().AddDate(0, 0, -((i*7)%365))
		if _, err := tx.Exec(txCtx, insertSQL, uid, email, name, status, createdAt); err != nil {
			logger.Errorf("insert user failed email=%s err=%v", email, err)
			continue
		}
		out = append(out, struct {
			UserID string
			Email  string
		}{UserID: uid, Email: email})
	}

	if err := tx.Commit(txCtx); err != nil {
		return nil, fmt.Errorf("commit users tx failed: %w", err)
	}
	logger.Infof("seeded %d users", len(out))
	return out, nil
}

// seedSubscriptions creates subscriptions for a subset of users deterministically.
func seedSubscriptions(ctx context.Context, pool *pgxpool.Pool, users []struct{ UserID, Email string }, seedVal int64, logger *zap.SugaredLogger) error {
	if len(users) == 0 {
		return errors.New("no users available")
	}
	gofakeit.Seed(uint64(seedVal + 1))

	txCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	tx, err := pool.Begin(txCtx)
	if err != nil {
		return fmt.Errorf("begin subscriptions tx failed: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	insertSQL := `INSERT INTO subscriptions (subscription_id, user_id, plan, status, renewal_date, billing_cycle_anchor, created_at)
VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT (subscription_id) DO NOTHING;`

	plans := []string{"free", "pro", "enterprise"}

	for i, u := range users {
		// skip some users (edge case without subscription)
		if i%10 == 9 {
			continue
		}
		sid, err := newULIDDet(seedVal+7, i+1)
		if err != nil {
			return err
		}
		plan := plans[i%len(plans)]
		status := "active"
		if i%17 == 0 {
			status = "past_due"
		}
		renewal := time.Now().UTC().AddDate(0, (i%3)+1, 0)
		billingAnchor := time.Now().UTC().AddDate(0, -((i%12)+1), 0)
		created := time.Now().UTC().AddDate(0, 0, -((i*3)%365))
		if _, err := tx.Exec(txCtx, insertSQL, sid, u.UserID, plan, status, renewal, billingAnchor, created); err != nil {
			logger.Errorf("insert subscription failed user=%s err=%v", u.Email, err)
			continue
		}
	}

	if err := tx.Commit(txCtx); err != nil {
		return fmt.Errorf("commit subscriptions tx failed: %w", err)
	}
	logger.Info("seeded subscriptions")
	return nil
}

// seedPayments creates deterministic payments for users, including duplicates and various statuses.
func seedPayments(ctx context.Context, pool *pgxpool.Pool, users []struct{ UserID, Email string }, total int, seedVal int64, logger *zap.SugaredLogger) error {
	if len(users) == 0 {
		return errors.New("no users to seed payments")
	}
	gofakeit.Seed(uint64(seedVal + 2))

	txCtx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()
	tx, err := pool.Begin(txCtx)
	if err != nil {
		return fmt.Errorf("begin payments tx failed: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	insertSQL := `INSERT INTO payments (payment_id, user_id, amount_cents, currency, status, created_at)
VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT DO NOTHING;`

	for i := 0; i < total; i++ {
		// deterministic mapping to a user
		userIdx := (i*7 + int(seedVal)) % len(users)
		user := users[userIdx]
		pid, err := newULIDDet(seedVal+100, i+1)
		if err != nil {
			return err
		}
		amount := int(gofakeit.Float64Range(5.00, 500.00) * 100)
		var status string
		switch {
		case i%13 == 0:
			status = "failed"
		case i%11 == 0:
			status = "refunded"
		default:
			status = "succeeded"
		}
		created := time.Now().UTC().AddDate(0, 0, -((i*2)%365))
		if _, err := tx.Exec(txCtx, insertSQL, pid, user.UserID, amount, "USD", status, created); err != nil {
			logger.Errorf("insert payment failed user=%s err=%v", user.Email, err)
			continue
		}
		// add a deliberate duplicate payment for certain iterations
		if i%37 == 0 {
			dupPid, derr := newULIDDet(seedVal+200, i+1)
			if derr == nil {
				if _, err := tx.Exec(txCtx, insertSQL, dupPid, user.UserID, amount, "USD", "succeeded", created.Add(10*time.Second)); err != nil {
					logger.Warnf("insert duplicate payment failed: %v", err)
				}
			}
		}
	}

	if err := tx.Commit(txCtx); err != nil {
		return fmt.Errorf("commit payments tx failed: %w", err)
	}
	logger.Infof("seeded %d payments", total)
	return nil
}

// kubectlPsqlDiagnostic executes a diagnostic SQL via kubectl exec into the postgres pod.
func kubectlPsqlDiagnostic(ctx context.Context, namespace string, logger *zap.SugaredLogger) error {
	out, err := runCmd(ctx, "kubectl", "get", "pod", "-n", namespace, "-l", "cnpg.io/cluster=postgres-cluster", "-o", "jsonpath={.items[0].metadata.name}")
	if err != nil {
		return fmt.Errorf("find postgres pod failed: %w", err)
	}
	pod := strings.TrimSpace(out)
	if pod == "" {
		return errors.New("postgres pod not found")
	}
	sql := `
SELECT 'users' AS table, count(*) AS rows FROM users
UNION ALL
SELECT 'subscriptions', count(*) FROM subscriptions
UNION ALL
SELECT 'payments', count(*) FROM payments;

SELECT user_id, email, account_status FROM users LIMIT 5;

SELECT subscription_id, user_id, plan, status FROM subscriptions LIMIT 5;

SELECT payment_id, user_id, amount_cents, status FROM payments LIMIT 5;
`
	output, err := runCmd(ctx, "kubectl", "exec", "-n", namespace, pod, "--", "psql", "-U", "postgres", "-d", targetDB, "-c", sql)
	if err != nil {
		logger.Warnf("kubectl psql diagnostic failed: %v", err)
		if output != "" {
			fmt.Println(output)
		}
		return err
	}
	fmt.Println(output)
	logger.Info("kubectl psql diagnostic executed")
	return nil
}

func main() {
	// configure zap logger (production config)
	logger, err := zap.NewProduction()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to init zap logger: %v\n", err)
		os.Exit(1)
	}
	defer func() { _ = logger.Sync() }()
	sugar := logger.Sugar()

	// context with signal handling
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	sugar.Info("bootstrap-demo-users starting")

	// read seed from env for deterministic runs
	seedVal := int64(2026)
	if env := os.Getenv("SEED"); env != "" {
		if parsed, perr := strconv.ParseInt(env, 10, 64); perr == nil {
			seedVal = parsed
		} else {
			sugar.Warnf("invalid SEED value %q, using default %d", env, seedVal)
		}
	}

	// read K8s secret fields for DB credentials
	user, err := k8sSecretField(ctx, k8sSecretName, k8sNamespace, "username")
	if err != nil {
		sugar.Fatalf("failed to read username secret: %v", err)
	}
	pass, err := k8sSecretField(ctx, k8sSecretName, k8sNamespace, "password")
	if err != nil {
		sugar.Fatalf("failed to read password secret: %v", err)
	}

	host := svcDNSName(poolerService, k8sNamespace)
	localPort := poolerPort
	var pfCmd *exec.Cmd
	if !svcResolvable(host) {
		sugar.Infof("service DNS %s not resolvable; starting port-forward", host)
		pfCmd, err = startPortForward(ctx, k8sNamespace, poolerService, localPort, poolerPort, sugar)
		if err != nil {
			sugar.Fatalf("port-forward failed: %v", err)
		}
		host = "127.0.0.1"
	} else {
		sugar.Infof("service DNS %s resolvable", host)
	}

	connURL := makeConnURL(user, pass, host, localPort, targetDB, connectTimeout)
	sugar.Debugf("connecting using host=%s db=%s", host, targetDB)

	pool, err := tryConnect(ctx, connURL, 60*time.Second, sugar)
	if err != nil {
		if pfCmd != nil {
			stopPortForward(pfCmd, sugar)
		}
		sugar.Fatalf("database not reachable: %v", err)
	}
	// ensure pool is closed on exit
	defer pool.Close()

	if err := ensureTables(ctx, pool, sugar); err != nil {
		if pfCmd != nil {
			stopPortForward(pfCmd, sugar)
		}
		sugar.Fatalf("failed to ensure tables: %v", err)
	}

	// deterministic seeding counts
	users, err := seedUsers(ctx, pool, 7, seedVal, sugar)
	if err != nil {
		if pfCmd != nil {
			stopPortForward(pfCmd, sugar)
		}
		sugar.Fatalf("seed users failed: %v", err)
	}

	if err := seedSubscriptions(ctx, pool, users, seedVal, sugar); err != nil {
		if pfCmd != nil {
			stopPortForward(pfCmd, sugar)
		}
		sugar.Fatalf("seed subscriptions failed: %v", err)
	}

	if err := seedPayments(ctx, pool, users, 12, seedVal, sugar); err != nil {
		if pfCmd != nil {
			stopPortForward(pfCmd, sugar)
		}
		sugar.Fatalf("seed payments failed: %v", err)
	}

	sugar.Info("bootstrap complete (users/subscriptions/payments)")

	// diagnostic: run kubectl psql (best-effort)
	if err := kubectlPsqlDiagnostic(ctx, k8sNamespace, sugar); err != nil {
		sugar.Warnf("kubectl diagnostic failed: %v", err)
	}

	if pfCmd != nil {
		stopPortForward(pfCmd, sugar)
	}
	sugar.Info("bootstrap-demo-users finished")
}