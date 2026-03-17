# docs/agents/all_pg_tables.md

## Purpose

Concise reference for the Postgres schema used by the `agents` database and the lifecycle for each table: creation/migration, seeding, runtime operations, auditing, maintenance, and retirement/archival. Designed for a solo engineer building a production-like demo.

---

## Tables (summary)

* `users` — customer identity
* `subscriptions` — subscription records per user
* `payments` — payment attempts / charges
* `refunds` — refunds issued (idempotent)
* `tickets` — incoming support tickets (queue source)
* `agent_runs` — agent execution runs per ticket
* `tool_calls` — audit of each tool invocation
* `ticket_events` — timeline events for ticket lifecycle
* `support_replies` — outbound replies / messages

---

## General lifecycle rules (applies to all tables)

1. **Creation**

   * Create via versioned migration (e.g. `migrations/001_create_users.sql`).
   * Migrations are idempotent and reversible when possible.

2. **Seeding**

   * Seed minimal deterministic fixtures via `cmd/seed_billing_scenarios`.
   * Seeds are safe to re-run (use `ON CONFLICT` where applicable).

3. **Runtime operations**

   * Reads: primary operations for lookup tools (`SELECT` with appropriate indexes).
   * Mutations: always perform in transactions; mutating tools require `idempotency_key` and insert a record in audit table (`tool_calls`/`refunds`/`support_replies`).
   * Worker queue: `tickets` consumed via `SELECT ... FOR UPDATE SKIP LOCKED`.

4. **Auditing & observability**

   * Every mutating action must create a `tool_calls` row with `request_payload` and `response_payload`.
   * Agent runs produce OTEL spans; include `run_id` in logs and DB rows.

5. **Maintenance**

   * Routine `VACUUM` / `ANALYZE` via scheduled jobs.
   * Monitor table sizes and index bloat; run `REINDEX` as needed.
   * Backups: daily physical snapshots + WAL archiving.

6. **Retention / Archival**

   * Short-term: keep `tickets`, `agent_runs`, `tool_calls` in DB for 90 days by default.
   * Long-term audit: export `tool_calls` and `ticket_events` to a cold store (S3/GS) every 90 days, then purge older rows.
   * Business data (`users`, `subscriptions`, `payments`, `refunds`) retained per legal / business rules (e.g., 7 years for payments).

7. **Access control**

   * Least privilege: `agent_service` role only on `agents`-scoped tables; `mcp_service` role only for business reads/writes as required.
   * Use separate DB users and connection pools.

8. **Testing**

   * Unit tests use mocks. Integration tests run migrations, seed fixtures, assert DB state and idempotency semantics.

---

## Table-by-table lifecycle

### `users`

**Purpose:** store customer identity and account status.
**Migration:** `001_create_users.sql`.
**Seed:** `cmd/seed_billing_scenarios` inserts 5–10 realistic rows.
**Runtime:** reads by `lookup_user` tool; updates rare (profile changes).
**Mutations:** `UPDATE account_status` performed by admin or automation with audit event in `ticket_events`.
**Indexes:** `CREATE UNIQUE INDEX ON users(email)`.
**Retention:** indefinite (subject to privacy policy).
**Useful checks:**

```sql
SELECT user_id, email, account_status FROM users WHERE email='foo@bar';
```

---

### `subscriptions`

**Purpose:** per-user subscription state.
**Migration:** `002_create_subscriptions.sql`.
**Seed:** seeded with subscription rows for seeded users.
**Runtime:** read by `get_subscription`; mutated by `cancel_subscription`.
**Mutations:** cancellations must be idempotent (`idempotency_key` in `support_replies`/`tool_calls`).
**Indexes:** `CREATE INDEX ON subscriptions(user_id)`.
**Retention:** keep for history; consider separate `subscription_history` table if many status changes.
**Useful checks:**

```sql
SELECT * FROM subscriptions WHERE user_id = $1 ORDER BY created_at DESC LIMIT 5;
```

---

### `payments`

**Purpose:** record charge attempts and statuses.
**Migration:** `003_create_payments.sql`.
**Seed:** seeded with succeeded/failed payment rows.
**Runtime:** read by `list_user_payments`; mutated by billing system integrations.
**Mutations:** status update (e.g., `succeeded` → `refunded`) must be accompanied by a `refunds` row and `tool_calls` entry.
**Indexes:** `CREATE INDEX idx_payments_user_created ON payments(user_id, created_at DESC)`.
**Retention:** business rules; keep original rows, mark with statuses. Archive older than retention period to cold storage if needed.
**Useful checks:**

```sql
SELECT * FROM payments WHERE user_id=$1 ORDER BY created_at DESC LIMIT 20;
```

---

### `refunds`

**Purpose:** canonical record of refunds issued by MCP tools.
**Migration:** `004_create_refunds.sql`.
**Seed:** normally empty; may include historical refunds for tests.
**Runtime:** created by `refund_payment` tool.
**Idempotency:** enforced via `idempotency_key` unique constraint. `refund_payment` must return `already_refunded` when same key used.
**Indexes:** `CREATE UNIQUE INDEX ON refunds(idempotency_key)`.
**Retention:** keep as part of payments history; ensure GDPR/financial record requirements.
**Useful checks:**

```sql
SELECT * FROM refunds WHERE payment_id=$1;
```

---

### `tickets`

**Purpose:** ingestion queue for support requests.
**Migration:** `005_create_tickets.sql`.
**Seed:** seed 5–10 demo tickets for E2E tests.
**Runtime:** created by `POST /tickets`; consumed by worker loop `SELECT ... FOR UPDATE SKIP LOCKED`.
**Mutations:** `status` transitions (`open` → `processing` → `resolved|escalated`) must be written inside worker transactions. Emit corresponding `ticket_events`.
**Indexes:** `CREATE INDEX idx_tickets_status_created ON tickets(status, created_at)`.
**Retention:** store resolved tickets for 90 days then archive; longer if required.
**Useful checks:**

```sql
SELECT ticket_id, status FROM tickets WHERE status='open' ORDER BY created_at LIMIT 10;
```

---

### `agent_runs`

**Purpose:** atomic run records for agent processing per ticket.
**Migration:** `006_create_agent_runs.sql`.
**Seed:** none. Created by worker when starting run.
**Runtime:** `INSERT` at run start, `UPDATE` on completion/failure. Include `started_at`, `completed_at`. Correlate with `tool_calls`.
**Indexes:** `CREATE INDEX idx_agent_runs_ticket ON agent_runs(ticket_id)`.
**Retention:** keep for 90 days; archive older runs if audit retention policy allows.
**Useful checks:**

```sql
SELECT * FROM agent_runs WHERE ticket_id=$1 ORDER BY started_at DESC LIMIT 5;
```

---

### `tool_calls`

**Purpose:** immutable audit of every tool invocation (request/response).
**Migration:** `007_create_tool_calls.sql`.
**Seed:** none.
**Runtime:** every tool (including read-only ones) should `INSERT` a `tool_calls` row with `run_id`, `tool_name`, `request_payload`, and `response_payload`. For calls outside an agent run, `run_id` may be NULL but still log.
**Indexes:** `CREATE INDEX idx_tool_calls_run ON tool_calls(run_id)` and `CREATE INDEX idx_tool_calls_toolname ON tool_calls(tool_name)`.
**Retention:** audit-critical; export older records to cold store after 1 year. Do not purge without legal approval.
**Useful checks:**

```sql
SELECT * FROM tool_calls WHERE run_id=$1 ORDER BY created_at;
```

---

### `ticket_events`

**Purpose:** timeline events for human-readable audit and debugging.
**Migration:** `008_create_ticket_events.sql`.
**Seed:** none.
**Runtime:** insert events on state transitions, errors, escalations, and manual interventions. Event payload is JSONB.
**Indexes:** `CREATE INDEX idx_ticket_events_ticket ON ticket_events(ticket_id)`.
**Retention:** mirror `agent_runs` retention (90 days) unless needed longer for audits.
**Useful checks:**

```sql
SELECT event_type, payload, created_at FROM ticket_events WHERE ticket_id=$1 ORDER BY created_at;
```

---

### `support_replies`

**Purpose:** outbound messages stitched to tickets. Enforces idempotency for outbound sends.
**Migration:** `009_create_support_replies.sql`.
**Seed:** none (tests may seed).
**Runtime:** created by `create_support_reply` tool after an action. Use `idempotency_key` to prevent duplicate sends.
**Indexes:** `CREATE UNIQUE INDEX ON support_replies(idempotency_key)` and `CREATE INDEX ON support_replies(ticket_id)`.
**Retention:** keep messages for 90–365 days; longer if compliance requires.
**Useful checks:**

```sql
SELECT * FROM support_replies WHERE ticket_id=$1;
```

---

## Migration & deployment notes

* Name migrations sequentially: `001_create_users.sql` ... `009_create_support_replies.sql`.
* Use a single migration runner binary `cmd/migrate` or embed migrations in `internal/db/migrations.go`.
* CI runs migrations against a disposable test DB before integration tests.
* When changing schema: write a forward migration and, if possible, a reversible down migration. Backfill data in a separate migration stage if needed.

---

## Idempotency & concurrency

* All mutating tools require an `idempotency_key` for safe retries; enforce unique constraints where applicable (`refunds.idempotency_key`, `support_replies.idempotency_key`).
* Worker consumption pattern: `BEGIN; SELECT ... FOR UPDATE SKIP LOCKED; UPDATE ticket SET status='processing', updated_at=now() WHERE ticket_id=$1; COMMIT;`
* Keep transactions short — perform external calls (HTTP to other services) outside DB transactions.

---

## Monitoring & alerts

* Monitor these metrics per table: row growth, write rate, index size, query latency (p50/p95).
* Alerts:

  * `tickets` backlog > threshold (e.g., >100 open tickets)
  * `tool_call_errors_total` rising > 1% of calls in 10m window
  * DB connections near pool limit
  * WAL lag / backup failures

---

## Backup & restore

* Daily full backup + continuous WAL archiving. Test restores monthly.
* For quick recovery of audit data, export `tool_calls`/`ticket_events` periodically to compressed NDJSON in object storage.

---

## Purge / archival examples

Archive `tool_calls` older than 365 days:

```sql
-- export to external store is recommended; below is a purge example:
WITH old AS (
  SELECT tool_call_id FROM tool_calls WHERE created_at < now() - INTERVAL '365 days' LIMIT 10000
)
DELETE FROM tool_calls WHERE tool_call_id IN (SELECT tool_call_id FROM old);
```

Purge `tickets` resolved > 180 days:

```sql
DELETE FROM tickets WHERE status='resolved' AND updated_at < now() - INTERVAL '180 days';
```

Always export to cold storage before destructive purges.

---

## Testing checklist (before running agent)

* Run migrations in clean DB.
* Run `cmd/seed_billing_scenarios` to populate `users`, `subscriptions`, `payments`.
* Create 5–10 `tickets` for demo scenarios (cancel, duplicate charge, failed payment).
* Execute unit tests, then integration tests that run against the migrated DB.
* Validate `tool_calls` are being written by tool stubs.

---

## Quick reference: sample migration filenames

* `001_create_users.sql`
* `002_create_subscriptions.sql`
* `003_create_payments.sql`
* `004_create_refunds.sql`
* `005_create_tickets.sql`
* `006_create_agent_runs.sql`
* `007_create_tool_calls.sql`
* `008_create_ticket_events.sql`
* `009_create_support_replies.sql`

---

## Operational tips for a solo engineer

* Keep retention conservative during development (longer retention) to aid debugging.
* Automate migration + seed in CI.
* Start with read-only tools (`lookup_user`, `list_user_payments`) to validate the DB contract before enabling mutating tools.
* Use deterministic UUIDs/timestamps in tests to make assertions stable.

---

End of document.
