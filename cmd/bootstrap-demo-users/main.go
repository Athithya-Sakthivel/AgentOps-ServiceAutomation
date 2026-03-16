// File: cmd/bootstrap-demo-users/main.go
package main

// Production-ready bootstrap binary to create and seed demo_users DB.
// Uses:
//   github.com/jackc/pgx/v5 v5.8.0
//   github.com/google/uuid v1.6.0
//   github.com/rs/zerolog v1.34.0
//
// Build:
//   go build -o bootstrap-demo-users ./cmd/bootstrap-demo-users
//
// Run (requires kubectl configured):
//   ./bootstrap-demo-users
//
// Behavior summary:
// - reads K8s secret postgres-cluster-app (username, password) via kubectl
// - resolves pooler DNS (postgres-pooler.default.svc.cluster.local) and
//   port-forwards to localhost if DNS is not resolvable
// - ensures demo tables exist in demo_users DB
// - seeds deterministic users/payments/incidents/knowledge
// - runs kubectl exec psql diagnostic against the postgres pod
// - cleans up port-forward on exit

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"math/rand"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
)

const (
	k8sSecretName  = "postgres-cluster-app"
	k8sNamespace   = "default"
	poolerService  = "postgres-pooler"
	poolerPort     = 5432
	targetDB       = "demo_users"
	connectTimeout = 5 // seconds, libpq connect_timeout
)

// runCmd runs a command with context and returns combined stdout+stderr as output.
// It logs debug information and returns error if the command fails.
func runCmd(ctx context.Context, name string, args ...string) (string, error) {
	log.Debug().Str("cmd", name).Strs("args", args).Msg("running command")
	cmd := exec.CommandContext(ctx, name, args...)
	// capture combined output (stdout+stderr) for easier diagnostics
	out, err := cmd.CombinedOutput()
	outStr := strings.TrimSpace(string(out))
	if err != nil {
		// include combined output in error
		return outStr, fmt.Errorf("command %s failed: %w; output: %s", strings.Join(append([]string{name}, args...), " "), err, outStr)
	}
	return outStr, nil
}

// k8sSecretField fetches a base64-encoded secret field using kubectl and decodes it.
func k8sSecretField(ctx context.Context, secret, namespace, field string) (string, error) {
	out, err := runCmd(ctx, "kubectl", "get", "secret", secret, "-n", namespace, "-o", fmt.Sprintf("jsonpath={.data.%s}", field))
	if err != nil {
		log.Error().Err(err).Str("field", field).Msg("kubectl get secret failed")
		return "", err
	}
	if out == "" {
		return "", fmt.Errorf("secret field %s is empty", field)
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

// waitForPort waits until host:port accepts a TCP connection or timeout expires.
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

// startPortForward starts kubectl port-forward in its own process group.
// Returns the exec.Cmd for later cleanup.
func startPortForward(ctx context.Context, namespace, svc string, localPort, remotePort int) (*exec.Cmd, error) {
	args := []string{"port-forward", fmt.Sprintf("svc/%s", svc), fmt.Sprintf("%d:%d", localPort, remotePort), "-n", namespace}
	cmd := exec.CommandContext(ctx, "kubectl", args...)
	// put into new process group so we can kill group
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// suppress output (kubectl prints status to stderr)
	cmd.Stdout = nil
	cmd.Stderr = nil

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start port-forward: %w", err)
	}
	if !waitForPort("127.0.0.1", localPort, 25*time.Second) {
		// best-effort kill process group
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		return nil, fmt.Errorf("port-forward failed to bind localhost:%d", localPort)
	}
	log.Info().Int("local_port", localPort).Msg("port-forward ready on localhost")
	return cmd, nil
}

// stopPortForward kills the port-forward process group and waits.
func stopPortForward(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	pid := cmd.Process.Pid
	log.Info().Int("pid", pid).Msg("stopping port-forward")
	_ = syscall.Kill(-pid, syscall.SIGTERM)
	_ = cmd.Process.Kill()
	_, _ = cmd.Process.Wait()
}

// urlEscape does minimal escaping for username/password to embed in URL.
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

// tryConnect repeatedly attempts to create a pgxpool and Ping until maxWait.
func tryConnect(ctx context.Context, connURL string, maxWait time.Duration) (*pgxpool.Pool, error) {
	deadline := time.Now().Add(maxWait)
	var lastErr error
	for time.Now().Before(deadline) {
		cfg, err := pgxpool.ParseConfig(connURL)
		if err != nil {
			return nil, fmt.Errorf("pgxpool parse config failed: %w", err)
		}
		// sane defaults for demo job
		if cfg.MaxConns == 0 {
			cfg.MaxConns = 8
		}
		pool, err := pgxpool.NewWithConfig(ctx, cfg)
		if err == nil {
			pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
			err = pool.Ping(pingCtx)
			cancel()
			if err == nil {
				return pool, nil
			}
			// ping failed: close pool and retry
			pool.Close()
		}
		lastErr = err
		log.Warn().Err(err).Msg("connect attempt failed; retrying")
		time.Sleep(1 * time.Second)
	}
	return nil, fmt.Errorf("unable to connect within %s: last error: %w", maxWait.String(), lastErr)
}

// ensureTables creates required demo tables if not present.
func ensureTables(ctx context.Context, pool *pgxpool.Pool) error {
	sql := `
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY,
    email TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    account_tier TEXT NOT NULL,
    signup_date TIMESTAMPTZ NOT NULL,
    last_login TIMESTAMPTZ,
    status TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_users_tier ON users(account_tier);

CREATE TABLE IF NOT EXISTS payments (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    amount NUMERIC NOT NULL,
    currency TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_payments_user ON payments(user_id);

CREATE TABLE IF NOT EXISTS user_incidents (
    id TEXT PRIMARY KEY,
    service TEXT NOT NULL,
    status TEXT NOT NULL,
    started_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS knowledge_articles (
    id UUID PRIMARY KEY,
    title TEXT NOT NULL,
    content TEXT NOT NULL
);
`
	ctxExec, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	_, err := pool.Exec(ctxExec, sql)
	if err != nil {
		return fmt.Errorf("ensureTables exec failed: %w", err)
	}
	log.Info().Msg("ensured demo tables exist")
	return nil
}

// seedUsers inserts deterministic users and returns DB-truth rows.
func seedUsers(ctx context.Context, pool *pgxpool.Pool, n int, seedVal int64) ([]struct {
	ID    string
	Email string
}, error) {
	r := rand.New(rand.NewSource(seedVal))
	first := []string{"alice", "bob", "carol", "dave", "erin", "frank", "grace", "heidi", "ivan", "judy", "karen", "leo", "mallory", "nancy", "oscar", "peggy", "quentin", "rachel", "sam", "trent", "uma", "victor", "wendy", "xavier", "yvonne", "zane"}
	last := []string{"payne", "auth", "billing", "order", "smith", "johnson", "williams", "brown", "jones", "miller"}
	tiers := []string{"free", "pro", "enterprise"}
	statuses := []string{"active", "suspended", "closed"}

	txCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	tx, err := pool.Begin(txCtx)
	if err != nil {
		return nil, fmt.Errorf("begin tx failed: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	insertSQL := `INSERT INTO users (id, email, name, account_tier, signup_date, last_login, status)
VALUES ($1,$2,$3,$4,$5,$6,$7)
ON CONFLICT (email) DO NOTHING;`

	emails := map[string]struct{}{}
	for i := 0; i < n; i++ {
		fn := first[r.Intn(len(first))]
		ln := last[r.Intn(len(last))]
		local := fmt.Sprintf("%s.%s", fn, ln)
		email := fmt.Sprintf("%s@demo.com", local)
		if _, ok := emails[email]; ok {
			email = fmt.Sprintf("%s%d@demo.com", local, r.Intn(999))
		}
		emails[email] = struct{}{}
		uid := uuid.New()
		name := fmt.Sprintf("%s %s", strings.Title(fn), strings.Title(ln))
		signup := time.Now().UTC().AddDate(0, 0, -r.Intn(1000))
		lastLogin := signup.AddDate(0, 0, r.Intn(300))
		tier := tiers[r.Intn(len(tiers))]
		status := statuses[0]
		if r.Float64() < 0.08 {
			status = statuses[1]
		} else if r.Float64() < 0.02 {
			status = statuses[2]
		}
		if _, err := tx.Exec(txCtx, insertSQL, uid, email, name, tier, signup, lastLogin, status); err != nil {
			log.Error().Err(err).Str("email", email).Msg("insert user failed")
		}
	}
	if err := tx.Commit(txCtx); err != nil {
		return nil, fmt.Errorf("commit users tx failed: %w", err)
	}

	rows, err := pool.Query(ctx, `SELECT id, email FROM users`)
	if err != nil {
		return nil, fmt.Errorf("fetch users failed: %w", err)
	}
	defer rows.Close()

	var out []struct {
		ID    string
		Email string
	}
	for rows.Next() {
		var id uuid.UUID
		var email string
		if err := rows.Scan(&id, &email); err != nil {
			return nil, fmt.Errorf("scan user row failed: %w", err)
		}
		out = append(out, struct {
			ID    string
			Email string
		}{ID: id.String(), Email: email})
	}
	log.Info().Int("present_users", len(out)).Msg("seeded users")
	return out, nil
}

// seedPayments inserts deterministic payments referencing provided users.
func seedPayments(ctx context.Context, pool *pgxpool.Pool, users []struct {
	ID    string
	Email string
}, total int, seedVal int64) error {
	if len(users) == 0 {
		return errors.New("no users to seed payments")
	}
	r := rand.New(rand.NewSource(seedVal))
	txCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	tx, err := pool.Begin(txCtx)
	if err != nil {
		return fmt.Errorf("begin payments tx failed: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	insertSQL := `INSERT INTO payments (id, user_id, amount, currency, status, created_at)
VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT DO NOTHING;`
	statuses := []string{"completed", "failed", "refunded", "pending"}

	for i := 0; i < total; i++ {
		pid := uuid.New()
		userID := users[r.Intn(len(users))].ID
		amt := float64(int((r.Float64()*495.0+5.0)*100)) / 100.0
		created := time.Now().UTC().AddDate(0, 0, -r.Intn(365))
		p := r.Float64()
		var status string
		switch {
		case p < 0.62:
			status = statuses[0]
		case p < 0.80:
			status = statuses[1]
		case p < 0.92:
			status = statuses[2]
		default:
			status = statuses[3]
		}
		if _, err := tx.Exec(txCtx, insertSQL, pid, userID, amt, "USD", status, created); err != nil {
			log.Error().Err(err).Msg("insert payment failed")
		}
	}
	if err := tx.Commit(txCtx); err != nil {
		return fmt.Errorf("commit payments tx failed: %w", err)
	}
	log.Info().Int("seeded_payments", total).Msg("seeded payments")
	return nil
}

func seedIncidents(ctx context.Context, pool *pgxpool.Pool) error {
	txCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	tx, err := pool.Begin(txCtx)
	if err != nil {
		return fmt.Errorf("begin incidents tx failed: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	stmt := `INSERT INTO user_incidents (id, service, status, started_at) VALUES ($1,$2,$3,$4)
ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status, started_at = EXCLUDED.started_at;`
	inc := []struct {
		ID        string
		Service   string
		Status    string
		StartedAt time.Time
	}{
		{"INC1001", "payments", "active", time.Now().UTC().Add(-6 * time.Hour)},
		{"INC1002", "auth", "resolved", time.Now().UTC().Add(-24 * time.Hour)},
	}
	for _, ii := range inc {
		if _, err := tx.Exec(txCtx, stmt, ii.ID, ii.Service, ii.Status, ii.StartedAt); err != nil {
			log.Error().Err(err).Str("incident", ii.ID).Msg("insert incident failed")
		}
	}
	if err := tx.Commit(txCtx); err != nil {
		return fmt.Errorf("commit incidents tx failed: %w", err)
	}
	log.Info().Msg("seeded incidents")
	return nil
}

func seedKnowledge(ctx context.Context, pool *pgxpool.Pool) error {
	txCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	tx, err := pool.Begin(txCtx)
	if err != nil {
		return fmt.Errorf("begin knowledge tx failed: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	articles := []struct {
		Title   string
		Content string
	}{
		{"Refund policy", "Refunds are issued within 5 business days. Refund eligibility is determined by payment status and order fulfillment."},
		{"Payment retry policy", "Failed payments can be retried up to 3 times in 24 hours. Use the retry endpoint to attempt a retry."},
		{"Password reset troubleshooting", "If password reset emails are not received, check spam, and validate user's email. Provide reset link TTL of 30 minutes."},
		{"Order not created after payment", "Investigate payment webhook delivery and order service logs. If payment succeeded but no order exists, create a compensating order and refund if necessary."},
	}
	stmt := `INSERT INTO knowledge_articles (id, title, content) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING;`
	for _, a := range articles {
		if _, err := tx.Exec(txCtx, stmt, uuid.New(), a.Title, a.Content); err != nil {
			log.Error().Err(err).Str("title", a.Title).Msg("insert article failed")
		}
	}
	if err := tx.Commit(txCtx); err != nil {
		return fmt.Errorf("commit knowledge tx failed: %w", err)
	}
	log.Info().Msg("seeded knowledge articles")
	return nil
}

// kubectlPsqlDiagnostic runs diagnostic SQL via kubectl exec against the postgres pod.
func kubectlPsqlDiagnostic(ctx context.Context, namespace string) error {
	out, err := runCmd(ctx, "kubectl", "get", "pod", "-n", namespace, "-l", "cnpg.io/cluster=postgres-cluster", "-o", "jsonpath={.items[0].metadata.name}")
	if err != nil {
		log.Error().Err(err).Msg("find postgres pod failed")
		return err
	}
	pod := strings.TrimSpace(out)
	if pod == "" {
		return errors.New("postgres pod not found")
	}
	sql := `
SELECT 'users' AS table, count(*) AS rows FROM users
UNION ALL
SELECT 'payments', count(*) FROM payments
UNION ALL
SELECT 'user_incidents', count(*) FROM user_incidents
UNION ALL
SELECT 'knowledge_articles', count(*) FROM knowledge_articles;

SELECT id,email,account_tier,status FROM users LIMIT 5;

SELECT user_id,amount,status,created_at FROM payments LIMIT 5;

SELECT * FROM user_incidents;

SELECT title FROM knowledge_articles;
`
	// Execute psql inside pod
	output, err := runCmd(ctx, "kubectl", "exec", "-n", namespace, pod, "--", "psql", "-U", "postgres", "-d", targetDB, "-c", sql)
	if err != nil {
		log.Error().Err(err).Str("output", output).Msg("kubectl psql diagnostic failed")
		return err
	}
	// Print diagnostic output to stdout (already captured); also log info
	fmt.Println(output)
	log.Info().Msg("kubectl psql diagnostic executed")
	return nil
}

func main() {
	// logger: JSON structured output
	zerolog.TimeFieldFormat = time.RFC3339
	log.Logger = log.Output(zerolog.ConsoleWriter{Out: os.Stdout, TimeFormat: time.RFC3339})

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	log.Info().Msg("bootstrap-demo-users starting")

	user, err := k8sSecretField(ctx, k8sSecretName, k8sNamespace, "username")
	if err != nil {
		log.Fatal().Err(err).Msg("failed to read username secret")
	}
	pass, err := k8sSecretField(ctx, k8sSecretName, k8sNamespace, "password")
	if err != nil {
		log.Fatal().Err(err).Msg("failed to read password secret")
	}

	host := svcDNSName(poolerService, k8sNamespace)
	localPort := poolerPort
	var pfCmd *exec.Cmd
	if !svcResolvable(host) {
		log.Info().Str("svc", host).Msg("service DNS not resolvable; starting port-forward")
		pfCmd, err = startPortForward(ctx, k8sNamespace, poolerService, localPort, poolerPort)
		if err != nil {
			log.Fatal().Err(err).Msg("port-forward failed")
		}
		host = "127.0.0.1"
	} else {
		log.Info().Str("svc", host).Msg("service DNS resolvable")
	}

	connURL := makeConnURL(user, pass, host, localPort, targetDB, connectTimeout)
	log.Debug().Str("conn_url", connURL).Msg("constructed connection URL (masked in logs)")

	pool, err := tryConnect(ctx, connURL, 60*time.Second)
	if err != nil {
		if pfCmd != nil {
			stopPortForward(pfCmd)
		}
		log.Fatal().Err(err).Msg("database not reachable")
	}
	defer pool.Close()

	if err := ensureTables(ctx, pool); err != nil {
		stopPortForward(pfCmd)
		log.Fatal().Err(err).Msg("failed to ensure tables")
	}

	users, err := seedUsers(ctx, pool, 40, 2026)
	if err != nil {
		stopPortForward(pfCmd)
		log.Fatal().Err(err).Msg("seed users failed")
	}
	if err := seedPayments(ctx, pool, users, 80, 2027); err != nil {
		stopPortForward(pfCmd)
		log.Fatal().Err(err).Msg("seed payments failed")
	}
	if err := seedIncidents(ctx, pool); err != nil {
		stopPortForward(pfCmd)
		log.Fatal().Err(err).Msg("seed incidents failed")
	}
	if err := seedKnowledge(ctx, pool); err != nil {
		stopPortForward(pfCmd)
		log.Fatal().Err(err).Msg("seed knowledge failed")
	}

	log.Info().Msg("bootstrap complete (users/payments/incidents/knowledge)")

	if err := kubectlPsqlDiagnostic(ctx, k8sNamespace); err != nil {
		log.Warn().Err(err).Msg("kubectl diagnostic failed; continuing")
	}

	if pfCmd != nil {
		stopPortForward(pfCmd)
	}
	log.Info().Msg("bootstrap-demo-users finished")
}