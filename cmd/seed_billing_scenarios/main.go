package main

import (
	"context"
	"database/sql"
	"encoding/hex"
	"flag"
	"fmt"
	"log"
	"math/rand"
	"os"
	"strconv"
	"strings"
	"time"

	_ "github.com/lib/pq"

	"github.com/brianvoe/gofakeit/v7"
	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/source/file"
	"github.com/golang-migrate/migrate/v4/database/postgres"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/oklog/ulid/v2"
)

const (
	defaultSeedUsers        = 7
	defaultSeedPayments     = 12
	defaultMigrationsFolder = "file://./migrations"
)

func main() {
	migrationsDir := flag.String("migrations", defaultMigrationsFolder, "migrations dir (file://...)")
	seedUsersCount := flag.Int("users", defaultSeedUsers, "number of users to seed")
	seedPaymentsCount := flag.Int("payments", defaultSeedPayments, "number of payments to seed")
	flag.Parse()

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Fatal("DATABASE_URL environment variable is required")
	}

	seedVal := int64(2026)
	if env := os.Getenv("SEED"); env != "" {
		if v, err := strconv.ParseInt(env, 10, 64); err == nil {
			seedVal = v
		} else {
			log.Printf("WARN: invalid SEED value %q, using default %d", env, seedVal)
		}
	}

	start := time.Now()
	log.Printf("START: seed_billing_scenarios - migrations=%s users=%d payments=%d seed=%d", *migrationsDir, *seedUsersCount, *seedPaymentsCount, seedVal)
	log.Printf("DB: %s", maskDatabaseURL(databaseURL))

	if err := applyMigrations(databaseURL, *migrationsDir); err != nil {
		log.Fatalf("ERROR: applyMigrations failed: %v", err)
	}
	log.Printf("OK: migrations applied (dir=%s)", *migrationsDir)

	ctx := context.Background()
	pool, err := openPool(ctx, databaseURL)
	if err != nil {
		log.Fatalf("ERROR: openPool failed: %v", err)
	}
	defer pool.Close()
	log.Printf("OK: connected to database (pgx pool)")

	users, err := seedUsers(ctx, pool, *seedUsersCount, seedVal)
	if err != nil {
		log.Fatalf("ERROR: seedUsers failed: %v", err)
	}
	log.Printf("OK: seeded %d users", len(users))

	if err := seedSubscriptions(ctx, pool, users, seedVal); err != nil {
		log.Fatalf("ERROR: seedSubscriptions failed: %v", err)
	}
	log.Printf("OK: seeded subscriptions")

	if err := seedPayments(ctx, pool, users, *seedPaymentsCount, seedVal); err != nil {
		log.Fatalf("ERROR: seedPayments failed: %v", err)
	}
	log.Printf("OK: seeded %d payments", *seedPaymentsCount)

	log.Println("---- SAMPLE DATA (first 5 rows each) ----")
	if err := printFirst5Users(ctx, pool); err != nil {
		log.Printf("WARN: printFirst5Users: %v", err)
	}
	if err := printFirst5Subscriptions(ctx, pool); err != nil {
		log.Printf("WARN: printFirst5Subscriptions: %v", err)
	}
	if err := printFirst5Payments(ctx, pool); err != nil {
		log.Printf("WARN: printFirst5Payments: %v", err)
	}
	log.Println("---- END SAMPLE DATA ----")

	elapsed := time.Since(start)
	log.Printf("COMPLETE: bootstrap finished in %s", elapsed.String())
}

func applyMigrations(databaseURL, migrationsDir string) error {
	db, err := sql.Open("postgres", databaseURL)
	if err != nil {
		return fmt.Errorf("sql.Open: %w", err)
	}
	defer db.Close()

	if err := db.Ping(); err != nil {
		return fmt.Errorf("db.Ping: %w", err)
	}

	driver, err := postgres.WithInstance(db, &postgres.Config{})
	if err != nil {
		return fmt.Errorf("postgres.WithInstance: %w", err)
	}

	m, err := migrate.NewWithDatabaseInstance(migrationsDir, "postgres", driver)
	if err != nil {
		return fmt.Errorf("migrate.NewWithDatabaseInstance: %w", err)
	}

	if err := m.Up(); err != nil && err != migrate.ErrNoChange {
		return fmt.Errorf("m.Up: %w", err)
	}
	return nil
}

func openPool(ctx context.Context, databaseURL string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("pgxpool.ParseConfig: %w", err)
	}
	if cfg.MaxConns == 0 {
		cfg.MaxConns = 4
	}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("pgxpool.NewWithConfig: %w", err)
	}
	pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("pgx pool Ping: %w", err)
	}
	return pool, nil
}

func newULIDDet(seedVal int64, idx int) (ulid.ULID, error) {
	base := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	msTime := base.Add(time.Duration(idx) * time.Millisecond)
	ts := ulid.Timestamp(msTime)
	src := rand.New(rand.NewSource(seedVal + int64(idx)))
	id, err := ulid.New(ts, src)
	if err != nil {
		return ulid.ULID{}, err
	}
	return id, nil
}

func ulidToUUIDString(u ulid.ULID) string {
	b := u[:]
	hexS := hex.EncodeToString(b)
	return fmt.Sprintf("%s-%s-%s-%s-%s", hexS[0:8], hexS[8:12], hexS[12:16], hexS[16:20], hexS[20:32])
}

func columnIsUUID(ctx context.Context, pool *pgxpool.Pool, table, column string) (bool, error) {
	var dataType sql.NullString
	q := `SELECT data_type FROM information_schema.columns WHERE table_name = $1 AND column_name = $2`
	row := pool.QueryRow(ctx, q, table, column)
	if err := row.Scan(&dataType); err != nil {
		if err == sql.ErrNoRows {
			return false, nil
		}
		return false, err
	}
	return strings.EqualFold(dataType.String, "uuid"), nil
}

func seedUsers(ctx context.Context, pool *pgxpool.Pool, n int, seedVal int64) ([]struct {
	UserID string
	Email  string
}, error) {
	if n <= 0 {
		return nil, fmt.Errorf("n must be > 0")
	}
	gofakeit.Seed(uint64(seedVal))

	tx, err := pool.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("begin tx: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	insertSQL := `INSERT INTO users (user_id, email, name, account_status, created_at) VALUES ($1,$2,$3,$4,$5) ON CONFLICT (email) DO NOTHING;`

	out := make([]struct {
		UserID string
		Email  string
	}, 0, n)

	needsUUID, err := columnIsUUID(ctx, pool, "users", "user_id")
	if err != nil {
		return nil, fmt.Errorf("detect users.user_id type: %w", err)
	}

	for i := 0; i < n; i++ {
		u, err := newULIDDet(seedVal, i+1)
		if err != nil {
			return nil, fmt.Errorf("ulid: %w", err)
		}
		var uidForInsert string
		if needsUUID {
			uidForInsert = ulidToUUIDString(u)
		} else {
			uidForInsert = u.String()
		}

		name := gofakeit.Name()
		username := strings.ToLower(gofakeit.Username())
		username = strings.Map(func(r rune) rune {
			if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '.' || r == '_' || r == '-' {
				return r
			}
			return -1
		}, username)
		email := fmt.Sprintf("%s%d@demo.local", username, i+1)
		status := "active"
		if i%17 == 0 {
			status = "past_due"
		} else if i%31 == 0 {
			status = "cancelled"
		}
		createdAt := time.Now().UTC().AddDate(0, 0, -((i*7)%365))
		if _, err := tx.Exec(ctx, insertSQL, uidForInsert, email, name, status, createdAt); err != nil {
			log.Printf("WARN: insert user failed email=%s err=%v", email, err)
			continue
		}
		out = append(out, struct {
			UserID string
			Email  string
		}{UserID: uidForInsert, Email: email})
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("commit users tx: %w", err)
	}
	return out, nil
}

func seedSubscriptions(ctx context.Context, pool *pgxpool.Pool, users []struct {
	UserID string
	Email  string
}, seedVal int64) error {
	if len(users) == 0 {
		return nil
	}
	gofakeit.Seed(uint64(seedVal + 1))

	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin subs tx: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	insertSQL := `INSERT INTO subscriptions (subscription_id, user_id, plan, status, renewal_date, billing_cycle_anchor, created_at) VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT (subscription_id) DO NOTHING;`
	plans := []string{"free", "pro", "enterprise"}

	needsUUIDUsers, err := columnIsUUID(ctx, pool, "users", "user_id")
	if err != nil {
		return fmt.Errorf("detect users.user_id type: %w", err)
	}
	needsUUIDSubs, err := columnIsUUID(ctx, pool, "subscriptions", "subscription_id")
	if err != nil {
		return fmt.Errorf("detect subscriptions.subscription_id type: %w", err)
	}

	for i, u := range users {
		if i%10 == 9 {
			continue
		}
		sidULID, err := newULIDDet(seedVal+7, i+1)
		if err != nil {
			return fmt.Errorf("ulid subs: %w", err)
		}
		var sidForInsert string
		if needsUUIDSubs {
			sidForInsert = ulidToUUIDString(sidULID)
		} else {
			sidForInsert = sidULID.String()
		}
		plan := plans[i%len(plans)]
		status := "active"
		if i%17 == 0 {
			status = "past_due"
		}
		renewal := time.Now().UTC().AddDate(0, (i%3)+1, 0)
		billingAnchor := time.Now().UTC().AddDate(0, -((i%12)+1), 0)
		created := time.Now().UTC().AddDate(0, 0, -((i*3)%365))

		userIDForInsert := u.UserID
		if needsUUIDUsers && len(userIDForInsert) == 26 { // ULID string stored earlier as string; convert if necessary
			parsed, err := ulid.Parse(userIDForInsert)
			if err == nil {
				userIDForInsert = ulidToUUIDString(parsed)
			}
		}

		if _, err := tx.Exec(ctx, insertSQL, sidForInsert, userIDForInsert, plan, status, renewal, billingAnchor, created); err != nil {
			log.Printf("WARN: insert subscription failed user=%s err=%v", u.Email, err)
			continue
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit subs tx: %w", err)
	}
	return nil
}

func seedPayments(ctx context.Context, pool *pgxpool.Pool, users []struct {
	UserID string
	Email  string
}, total int, seedVal int64) error {
	if len(users) == 0 || total <= 0 {
		return nil
	}
	gofakeit.Seed(uint64(seedVal + 2))

	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin payments tx: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	insertSQL := `INSERT INTO payments (payment_id, user_id, amount_cents, currency, status, created_at) VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT DO NOTHING;`

	needsUUIDPayments, err := columnIsUUID(ctx, pool, "payments", "payment_id")
	if err != nil {
		return fmt.Errorf("detect payments.payment_id type: %w", err)
	}
	needsUUIDUsers, err := columnIsUUID(ctx, pool, "users", "user_id")
	if err != nil {
		return fmt.Errorf("detect users.user_id type: %w", err)
	}

	for i := 0; i < total; i++ {
		userIdx := (i*7 + int(seedVal)) % len(users)
		user := users[userIdx]

		pidULID, err := newULIDDet(seedVal+100, i+1)
		if err != nil {
			return fmt.Errorf("ulid payments: %w", err)
		}
		var pidForInsert string
		if needsUUIDPayments {
			pidForInsert = ulidToUUIDString(pidULID)
		} else {
			pidForInsert = pidULID.String()
		}

		userIDForInsert := user.UserID
		if needsUUIDUsers && len(userIDForInsert) == 26 {
			parsed, err := ulid.Parse(userIDForInsert)
			if err == nil {
				userIDForInsert = ulidToUUIDString(parsed)
			}
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
		if _, err := tx.Exec(ctx, insertSQL, pidForInsert, userIDForInsert, amount, "USD", status, created); err != nil {
			log.Printf("WARN: insert payment failed user=%s err=%v", user.Email, err)
			continue
		}

		if i%37 == 0 {
			dupULID, derr := newULIDDet(seedVal+200, i+1)
			if derr == nil {
				var dupPid string
				if needsUUIDPayments {
					dupPid = ulidToUUIDString(dupULID)
				} else {
					dupPid = dupULID.String()
				}
				if _, err := tx.Exec(ctx, insertSQL, dupPid, userIDForInsert, amount, "USD", "succeeded", created.Add(10*time.Second)); err != nil {
					log.Printf("WARN: insert duplicate payment failed: %v", err)
				}
			}
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit payments tx: %w", err)
	}
	return nil
}

func printFirst5Users(ctx context.Context, pool *pgxpool.Pool) error {
	rows, err := pool.Query(ctx, `SELECT user_id, email, account_status, created_at FROM users ORDER BY created_at DESC LIMIT 5`)
	if err != nil {
		return fmt.Errorf("query users: %w", err)
	}
	defer rows.Close()

	log.Println("USERS (first 5):")
	var any bool
	for rows.Next() {
		var id, email, status string
		var created time.Time
		if err := rows.Scan(&id, &email, &status, &created); err != nil {
			return fmt.Errorf("scan users: %w", err)
		}
		fmt.Printf("  - %s | %s | %s | %s\n", id, email, status, created.UTC().Format(time.RFC3339))
		any = true
	}
	if !any {
		fmt.Println("  (no users found)")
	}
	return rows.Err()
}

func printFirst5Subscriptions(ctx context.Context, pool *pgxpool.Pool) error {
	rows, err := pool.Query(ctx, `SELECT subscription_id, user_id, plan, status, renewal_date FROM subscriptions ORDER BY created_at DESC LIMIT 5`)
	if err != nil {
		return fmt.Errorf("query subscriptions: %w", err)
	}
	defer rows.Close()

	log.Println("SUBSCRIPTIONS (first 5):")
	var any bool
	for rows.Next() {
		var sid, uid, plan, status string
		var renewal sql.NullTime
		if err := rows.Scan(&sid, &uid, &plan, &status, &renewal); err != nil {
			return fmt.Errorf("scan subs: %w", err)
		}
		renewalStr := "(nil)"
		if renewal.Valid {
			renewalStr = renewal.Time.UTC().Format(time.RFC3339)
		}
		fmt.Printf("  - %s | user=%s | %s | %s | renewal=%s\n", sid, uid, plan, status, renewalStr)
		any = true
	}
	if !any {
		fmt.Println("  (no subscriptions found)")
	}
	return rows.Err()
}

func printFirst5Payments(ctx context.Context, pool *pgxpool.Pool) error {
	rows, err := pool.Query(ctx, `SELECT payment_id, user_id, amount_cents, status, created_at FROM payments ORDER BY created_at DESC LIMIT 5`)
	if err != nil {
		return fmt.Errorf("query payments: %w", err)
	}
	defer rows.Close()

	log.Println("PAYMENTS (first 5):")
	var any bool
	for rows.Next() {
		var pid, uid, status string
		var amount int
		var created time.Time
		if err := rows.Scan(&pid, &uid, &amount, &status, &created); err != nil {
			return fmt.Errorf("scan payments: %w", err)
		}
		fmt.Printf("  - %s | user=%s | %d cents | %s | %s\n", pid, uid, amount, status, created.UTC().Format(time.RFC3339))
		any = true
	}
	if !any {
		fmt.Println("  (no payments found)")
	}
	return rows.Err()
}

func maskDatabaseURL(raw string) string {
	if idx := strings.Index(raw, "://"); idx != -1 {
		rest := raw[idx+3:]
		if at := strings.Index(rest, "@"); at != -1 {
			creds := rest[:at]
			if colon := strings.Index(creds, ":"); colon != -1 {
				user := creds[:colon]
				return raw[:idx+3] + user + ":***@" + rest[at+1:]
			}
		}
	}
	return raw
}