#!/usr/bin/env python3
"""
e2e bootstrap script for demo_users DB.

- installs python deps if missing
- fetches k8s secret for credentials
- starts kubectl port-forward if service DNS not resolvable
- creates demo tables
- seeds deterministic users/payments/incidents/knowledge
- runs a kubectl/psql diagnostic inside the postgres pod and prints output

No CLI args — everything runs in one shot.
"""
from __future__ import annotations

import base64
import datetime
import logging
import os
import random
import socket
import signal
import subprocess
import sys
import time
import uuid
from contextlib import suppress

# local imports will be attempted after deps are ensured
try:
    import psycopg  # type: ignore
    from psycopg_pool import ConnectionPool  # type: ignore
except Exception:
    psycopg = None
    ConnectionPool = None

# logging
logging.basicConfig(level=logging.INFO, format='{"time":"%(asctime)s","level":"%(levelname)s","message":"%(message)s"}')
logger = logging.getLogger("bootstrap_demo_users_e2e")

def run(cmd: list[str], check: bool = False, capture: bool = True, timeout: int | None = None) -> tuple[int, str, str]:
    logger.info("run: %s", " ".join(cmd))
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE if capture else None,
                              stderr=subprocess.PIPE if capture else None,
                              text=True, timeout=timeout, check=check)
        out = proc.stdout or ""
        err = proc.stderr or ""
        if capture:
            logger.debug("stdout: %s", out.strip())
            logger.debug("stderr: %s", err.strip())
        return proc.returncode, out, err
    except subprocess.CalledProcessError as e:
        logger.error("command failed rc=%s stderr=%s", e.returncode, e.stderr or "")
        raise
    except subprocess.TimeoutExpired as e:
        logger.error("command timeout after %ss", timeout)
        raise

def ensure_python_deps() -> None:
    global psycopg, ConnectionPool
    try:
        import psycopg  # type: ignore
        from psycopg_pool import ConnectionPool as _CP  # type: ignore
        psycopg = psycopg
        ConnectionPool = _CP
        logger.info("python deps already installed")
        return
    except Exception:
        logger.info("installing python deps (psycopg[binary], psycopg_pool)")
    cmd = [sys.executable, "-m", "pip", "install", "-q", "psycopg[binary]", "psycopg_pool"]
    try:
        run(cmd, check=True, timeout=600)
    except Exception:
        logger.exception("pip install failed")
        # proceed — maybe packages are present; try import
    try:
        import psycopg  # type: ignore
        from psycopg_pool import ConnectionPool as _CP  # type: ignore
        psycopg = psycopg
        ConnectionPool = _CP
        logger.info("python deps available")
    except Exception as e:
        logger.exception("required python packages missing after install attempt: %s", e)
        raise SystemExit(1)

def k8s_secret_field(secret: str, namespace: str, field: str) -> str:
    cmd = ["kubectl", "get", "secret", secret, "-n", namespace, "-o", f"jsonpath={{.data.{field}}}"]
    _, out, _ = run(cmd, check=True, timeout=15)
    if not out:
        raise RuntimeError(f"empty secret field {field}")
    return base64.b64decode(out.strip().encode()).decode()

def svc_dns_name(svc: str, namespace: str) -> str:
    return f"{svc}.{namespace}.svc.cluster.local"

def svc_resolvable(hostname: str) -> bool:
    try:
        socket.gethostbyname(hostname)
        return True
    except Exception:
        return False

def wait_for_port(host: str, port: int, timeout: int = 20) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=2):
                return True
        except Exception:
            time.sleep(0.3)
    return False

def start_port_forward(namespace: str, svc: str, local_port: int = 5432, remote_port: int = 5432):
    cmd = ["kubectl", "port-forward", f"svc/{svc}", f"{local_port}:{remote_port}", "-n", namespace]
    logger.info("starting port-forward: %s", " ".join(cmd))
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, preexec_fn=os.setsid)
    if not wait_for_port("127.0.0.1", local_port, timeout=25):
        with suppress(Exception):
            os.killpg(proc.pid, signal.SIGTERM)
        raise RuntimeError("port-forward failed to bind localhost:%d" % local_port)
    logger.info("port-forward ready on localhost:%d", local_port)
    return proc

def stop_port_forward(proc):
    if not proc:
        return
    try:
        if proc.poll() is None:
            logger.info("stopping port-forward pid=%s", proc.pid)
            os.killpg(proc.pid, signal.SIGTERM)
            # give it a moment
            time.sleep(0.3)
    except Exception as e:
        logger.warning("error stopping port-forward: %s", e)

def make_conninfo(user: str, password: str, host: str, port: int, db: str, connect_timeout: int = 5) -> str:
    # use libpq-style key=val string — psycopg.connect accepts this
    parts = [
        f"host={host}",
        f"port={port}",
        f"dbname={db}",
        f"user={user}",
        f"password={password}",
        f"connect_timeout={connect_timeout}",
        "application_name=bootstrap_demo_users"
    ]
    return " ".join(parts)

def ensure_tables(conn) -> None:
    cur = conn.cursor()
    cur.execute("""
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY,
    email TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    account_tier TEXT NOT NULL,
    signup_date TIMESTAMPTZ NOT NULL,
    last_login TIMESTAMPTZ,
    status TEXT NOT NULL
);
""")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_users_tier ON users(account_tier);")
    cur.execute("""
CREATE TABLE IF NOT EXISTS payments (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    amount NUMERIC NOT NULL,
    currency TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL
);
""")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_payments_user ON payments(user_id);")
    cur.execute("""
CREATE TABLE IF NOT EXISTS user_incidents (
    id TEXT PRIMARY KEY,
    service TEXT NOT NULL,
    status TEXT NOT NULL,
    started_at TIMESTAMPTZ NOT NULL
);
""")
    cur.execute("""
CREATE TABLE IF NOT EXISTS knowledge_articles (
    id UUID PRIMARY KEY,
    title TEXT NOT NULL,
    content TEXT NOT NULL
);
""")
    conn.commit()
    cur.close()
    logger.info("ensured demo tables exist")

def seed_users(conn, n=40, seed=2026) -> list[dict]:
    random.seed(seed)
    first = ["alice","bob","carol","dave","erin","frank","grace","heidi","ivan","judy","karen","leo","mallory","nancy","oscar","peggy","quentin","rachel","sam","trent","uma","victor","wendy","xavier","yvonne","zane"]
    last = ["payne","auth","billing","order","smith","johnson","williams","brown","jones","miller"]
    tiers = ["free","pro","enterprise"]
    users = []
    cur = conn.cursor()
    emails = set()
    for _ in range(n):
        fn = random.choice(first)
        ln = random.choice(last)
        local = f"{fn}.{ln}"
        email = f"{local}@demo.com"
        if email in emails:
            email = f"{local}{random.randint(1,999)}@demo.com"
        emails.add(email)
        uid = uuid.uuid4()
        signup = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=random.randint(1,1000))
        last_login = signup + datetime.timedelta(days=random.randint(0, min(300, (datetime.datetime.now(datetime.timezone.utc)-signup).days)))
        tier = random.choices(tiers, weights=[0.5,0.375,0.125], k=1)[0]
        status = random.choices(["active","suspended","closed"], weights=[0.9,0.08,0.02], k=1)[0]
        cur.execute("""
INSERT INTO users (id, email, name, account_tier, signup_date, last_login, status)
VALUES (%s,%s,%s,%s,%s,%s,%s)
ON CONFLICT (email) DO NOTHING;
""", (str(uid), email, f"{fn.capitalize()} {ln.capitalize()}", tier, signup, last_login, status))
        users.append({"id": str(uid), "email": email})
    conn.commit()
    # fetch actual ids present to ensure we use DB truth (handles ON CONFLICT DO NOTHING)
    cur.execute("SELECT id,email FROM users;")
    rows = cur.fetchall()
    existing = [{"id": str(r[0]), "email": r[1]} for r in rows]
    cur.close()
    logger.info("seeded users (requested=%d, present=%d)", n, len(existing))
    return existing

def seed_payments(conn, users: list[dict], total=80, seed=2027) -> list[str]:
    if not users:
        raise RuntimeError("no users available to seed payments")
    random.seed(seed)
    cur = conn.cursor()
    statuses = ["completed","failed","refunded","pending"]
    payments = []
    # use DB-backed user ids (safe)
    user_ids = [u["id"] for u in users]
    for _ in range(total):
        pid = uuid.uuid4()
        user_id = random.choice(user_ids)
        amt = round(random.uniform(5.0, 500.0), 2)
        created = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=random.randint(0,365))
        status = random.choices(statuses, weights=[0.62,0.18,0.12,0.08], k=1)[0]
        cur.execute("""
INSERT INTO payments (id, user_id, amount, currency, status, created_at)
VALUES (%s,%s,%s,%s,%s,%s)
ON CONFLICT DO NOTHING;
""", (str(pid), user_id, amt, "USD", status, created))
        payments.append(str(pid))
    conn.commit()
    cur.close()
    logger.info("seeded payments=%d", len(payments))
    return payments

def seed_incidents(conn) -> list[tuple]:
    cur = conn.cursor()
    inc = [
        ("INC1001","payments","active", datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=6)),
        ("INC1002","auth","resolved", datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=1))
    ]
    for row in inc:
        cur.execute("""
INSERT INTO user_incidents (id, service, status, started_at)
VALUES (%s,%s,%s,%s)
ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status, started_at = EXCLUDED.started_at;
""", row)
    conn.commit()
    cur.close()
    logger.info("seeded incidents")
    return inc

def seed_knowledge(conn) -> list[tuple]:
    cur = conn.cursor()
    articles = [
        ("Refund policy","Refunds are issued within 5 business days. Refund eligibility is determined by payment status and order fulfillment."),
        ("Payment retry policy","Failed payments can be retried up to 3 times in 24 hours. Use the retry endpoint to attempt a retry."),
        ("Password reset troubleshooting","If password reset emails are not received, check spam, and validate user's email. Provide reset link TTL of 30 minutes."),
        ("Order not created after payment","Investigate payment webhook delivery and order service logs. If payment succeeded but no order exists, create a compensating order and refund if necessary.")
    ]
    for title, content in articles:
        cur.execute("""
INSERT INTO knowledge_articles (id, title, content)
VALUES (%s,%s,%s)
ON CONFLICT DO NOTHING;
""", (str(uuid.uuid4()), title, content))
    conn.commit()
    cur.close()
    logger.info("seeded knowledge articles")
    return articles

def try_connect(conninfo: str, max_wait: int = 60) -> None:
    deadline = time.time() + max_wait
    last_exc = None
    while time.time() < deadline:
        try:
            conn = psycopg.connect(conninfo=conninfo)
            conn.close()
            return
        except Exception as e:
            last_exc = e
            logger.warning("connect attempt failed: %s; retrying...", e)
            time.sleep(1)
    raise RuntimeError(f"unable to connect to DB within {max_wait}s; last error: {last_exc}")

def find_postgres_pod(namespace: str = "default", label_selector: str = "cnpg.io/cluster=postgres-cluster") -> str:
    cmd = ["kubectl", "get", "pod", "-n", namespace, "-l", label_selector, "-o", "jsonpath={.items[0].metadata.name}"]
    _, out, _ = run(cmd, check=True, timeout=15)
    pod = out.strip()
    if not pod:
        raise RuntimeError("postgres pod not found")
    logger.info("found postgres pod: %s", pod)
    return pod

def kubectl_psql_diagnostic(namespace: str = "default") -> None:
    pod = find_postgres_pod(namespace=namespace)
    sql = """
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
"""
    cmd = ["kubectl", "exec", "-n", namespace, pod, "--", "psql", "-U", "postgres", "-d", "demo_users", "-c", sql]
    rc, out, err = run(cmd, check=True, timeout=60)
    print(out)

def main() -> None:
    # configuration
    secret = "postgres-cluster-app"
    namespace = "default"
    svc = "postgres-pooler"
    db = "demo_users"
    port = 5432
    port_proc = None

    # ensure deps
    ensure_python_deps()

    # get credentials
    try:
        user = k8s_secret_field(secret, namespace, "username")
        password = k8s_secret_field(secret, namespace, "password")
    except Exception as e:
        logger.exception("failed to read kubernetes secret: %s", e)
        raise SystemExit(1)

    # prepare host: try cluster DNS first, else port-forward to localhost
    host = svc_dns_name(svc, namespace)
    if not svc_resolvable(host):
        logger.info("service DNS %s not resolvable from this host; establishing port-forward", host)
        try:
            port_proc = start_port_forward(namespace=namespace, svc=svc, local_port=5432, remote_port=port)
            host = "127.0.0.1"
            port = 5432
        except Exception as e:
            logger.exception("port-forward failed: %s", e)
            raise SystemExit(1)
    else:
        logger.info("service DNS %s resolvable", host)

    conninfo = make_conninfo(user, password, host, port, db, connect_timeout=5)
    logger.info("constructed conninfo")

    # wait for DB reachable
    try:
        try_connect(conninfo, max_wait=60)
    except Exception as e:
        logger.exception("database not reachable: %s", e)
        stop_port_forward(port_proc)
        raise SystemExit(1)

    # use ConnectionPool for operations
    pool = ConnectionPool(conninfo=conninfo, min_size=1, max_size=4)
    try:
        with pool.connection() as conn:
            ensure_tables(conn)
            users = seed_users(conn, n=40)
            payments = seed_payments(conn, users, total=80)
            inc = seed_incidents(conn)
            articles = seed_knowledge(conn)
        logger.info("bootstrap complete: users=%d payments=%d incidents=%d articles=%d", len(users), len(payments), len(inc), len(articles))
        # run diagnostic inside the cluster (psql as postgres)
        try:
            kubectl_psql_diagnostic(namespace=namespace)
        except Exception:
            logger.exception("kubectl diagnostic failed")
    finally:
        # close pool and then stop port-forward
        try:
            pool.close()  # type: ignore[attr-defined]
        except Exception:
            pass
        stop_port_forward(port_proc)

if __name__ == "__main__":
    main()



