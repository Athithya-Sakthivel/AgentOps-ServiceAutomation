# docs/agents/seed_billing_scenarios.md

## Purpose

Bootstrap the `agents` Postgres database with minimal billing/sample data used by the demo MCP/agent stack. This script is idempotent and safe to re-run. It ensures required business tables exist and inserts seed users, subscriptions, and payments.

## Location

`cmd/seed_billing_scenarios` → builds to `bin/seed_billing_scenarios`

## Prerequisites

* Go toolchain for `make build` (the repository Makefile provides `build`)
* `kubectl` available in PATH if the script needs to port-forward to a cluster Postgres
* Docker / local Postgres reachable if not using the cluster
* Environment variables or config that point the seeder at the Postgres connection (the binary will fall back to port-forwarding if DNS unresolved)

## How to run

Build then run with an optional seed tag:

```sh
make build
SEED=2026 ./bin/seed_billing_scenarios
```

* `SEED` is optional; used by the seeder to vary deterministic random data.
* The command prints logs to stdout (structured JSON in the current implementation).

## What the script does (minimal)

1. Attempts to connect to the configured Postgres host.
2. If DNS for the cluster Postgres is not resolvable, starts a `kubectl port-forward` fallback.
3. Ensures required tables (users, subscriptions, payments) exist.
4. Inserts seed users, subscriptions, and payments.
5. Runs a simple diagnostic `psql` query and shuts down the port-forward if started.

> Note: The script currently seeds only `users`, `subscriptions`, and `payments`. Additional agent tables (refunds, tickets, agent_runs, tool_calls, ticket_events, support_replies) are **not** created by this script and must be added via migrations before running the full MCP/agent stack.

## Expected minimal confirmation

After successful run you should see logs indicating:

* connection established
* tables ensured
* counts of seeded rows for `users`, `subscriptions`, and `payments`
* port-forward lifecycle if applicable
* final "bootstrap finished" message

## Captured run (example)

Below is the full stdout that was produced when the seeder was executed in your environment (included verbatim):

```
root@LAPTOP-V0HV1VU3:/workspace# make build
mkdir -p bin && \
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
go build -trimpath -buildvcs=false -ldflags="-s -w -buildid=" -o bin/seed_billing_scenarios ./cmd/seed_billing_scenarios
root@LAPTOP-V0HV1VU3:/workspace# SEED=2026 ./bin/seed_billing_scenarios
{"level":"info","ts":1773707569.0084596,"caller":"seed_billing_scenarios/main.go:469","msg":"bootstrap-demo-users starting"}
{"level":"info","ts":1773707569.2077165,"caller":"seed_billing_scenarios/main.go:495","msg":"service DNS postgres-pooler.default.svc.cluster.local not resolvable; starting port-forward"}
Forwarding from 127.0.0.1:5432 -> 5432
Forwarding from [::1]:5432 -> 5432
{"level":"info","ts":1773707569.509866,"caller":"seed_billing_scenarios/main.go:119","msg":"port-forward ready on localhost:5432 (pid=23085)"}
Handling connection for 5432
Handling connection for 5432
{"level":"info","ts":1773707569.551803,"caller":"seed_billing_scenarios/main.go:167","msg":"connected to database"}
{"level":"info","ts":1773707569.5829892,"caller":"seed_billing_scenarios/main.go:222","msg":"ensured tables exist"}
{"level":"info","ts":1773707569.6208403,"caller":"seed_billing_scenarios/main.go:306","msg":"seeded 7 users"}
{"level":"info","ts":1773707569.6544492,"caller":"seed_billing_scenarios/main.go:356","msg":"seeded subscriptions"}
{"level":"info","ts":1773707569.7108333,"caller":"seed_billing_scenarios/main.go:415","msg":"seeded 12 payments"}
{"level":"info","ts":1773707569.7109842,"caller":"seed_billing_scenarios/main.go:548","msg":"bootstrap complete (users/subscriptions/payments)"}
Defaulted container "postgres" out of: postgres, bootstrap-controller (init)
     table     | rows 
---------------+------
 users         |    7
 subscriptions |    7
 payments      |   13
(3 rows)

          user_id           |             email              | account_status 
----------------------------+--------------------------------+----------------
 01HK153X01K7DWH0P901KEJX33 | beetle.491@demo.local          | past_due
 01HK153X02DXGZX5BV9DK02TC6 | ouisaarrell2@demo.local        | active
 01HK153X039HFC952CEYJK4H1V | emi2683@demo.local             | active
 01HK153X045BNNJTJAFRJMJNXW | chimpanzee_114@demo.local      | active
 01HK153X05FXGCY1R8100P54NZ | hakespeareanimpala5@demo.local | active
(5 rows)

      subscription_id       |          user_id           |    plan    |  status  
----------------------------+----------------------------+------------+----------
 01HK153X0121M0ZYC8FTST4PKW | 01HK153X01K7DWH0P901KEJX33 | free       | past_due
 01HK153X02XMP7AD49ZTSW4VQZ | 01HK153X02DXGZX5BV9DK02TC6 | pro        | active
 01HK153X038FQ0MJTAGBRF5J80 | 01HK153X039HFC952CEYJK4H1V | enterprise | active
 01HK153X04M1KY0JA81NQ0NF85 | 01HK153X045BNNJTJAFRJMJNXW | free       | active
 01HK153X05FVE3B785GWSJ5628 | 01HK153X05FXGCY1R8100P54NZ | pro        | active
(5 rows)

         payment_id         |          user_id           | amount_cents |  status   
----------------------------+----------------------------+--------------+-----------
 01HK153X01DS58XX7K38FZN50G | 01HK153X045BNNJTJAFRJMJNXW |        36974 | failed
 01HK153X019K4SARJCXWM786HJ | 01HK153X045BNNJTJAFRJMJNXW |        36974 | succeeded
 01HK153X02SG5Y9MX14BG1QM5N | 01HK153X045BNNJTJAFRJMJNXW |        48556 | succeeded
 01HK153X0356CPKVHFKQDJNRJP | 01HK153X045BNNJTJAFRJMJNXW |        23872 | succeeded
 01HK153X04ZZCKW8ZHHVADQQ4X | 01HK153X045BNNJTJAFRJMJNXW |        35149 | succeeded
(5 rows)
{"level":"info","ts":1773707570.0748158,"caller":"seed_billing_scenarios/main.go:451","msg":"kubectl psql diagnostic executed"}
{"level":"info","ts":1773707570.0751257,"caller":"seed_billing_scenarios/main.go:129","msg":"stopping port-forward (pid=23085)"}
{"level":"info","ts":1773707570.0831604,"caller":"seed_billing_scenarios/main.go:558","msg":"bootstrap-demo-users finished"}
root@LAPTOP-V0HV1VU3:/workspace#
```

## Troubleshooting notes

* If you see `service DNS ... not resolvable; starting port-forward` the binary used port-forward to reach cluster Postgres. This is expected when DNS or in-cluster networking is unavailable from your shell.
* If the binary cannot bind `127.0.0.1:5432` because another Postgres is running locally, stop the local Postgres or adjust port-forward target port.
* If seeding fails with permission errors, confirm the DB user has CREATE/INSERT privileges for the target database.

## Next recommended actions

1. Add the remaining agent tables via migrations: `refunds`, `tickets`, `agent_runs`, `tool_calls`, `ticket_events`, `support_replies`.
2. Extend seeder to add `tickets` fixtures (5–10 demo tickets).
3. Implement `lookup_user.go` and `list_user_payments.go` tools and create unit tests for them.
4. Run integration tests once the remaining migrations are in place.

---

Document created for `docs/agents/seed_billing_scenarios.md`.
