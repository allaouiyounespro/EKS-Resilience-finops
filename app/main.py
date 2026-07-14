"""Witness application for the resilience experiment.

owner: allaouiyounespro
portfolio: github.com/allaouiyounespro

This service exists to be *measured*, not to be useful. Three endpoints carry the
entire experiment:

    GET  /healthz   liveness  - is this process alive
    GET  /readyz    readiness - can this process reach the database
    POST /write     the RPO instrument: append a monotonic sequence number,
                    commit it, and only then acknowledge it
    GET  /last      the RPO readout: what is the highest sequence number the
                    database still admits to having

The RPO measurement hangs entirely on /write being honest about durability. It
acknowledges a sequence number only after COMMIT returns. So any gap between
"the last seq the client saw acknowledged" and "the highest seq in the database
after recovery" is, by construction, committed data that AWS lost. That is the
real definition of RPO, and it is the one number in this project you cannot fake.

Separating /healthz from /readyz matters just as much for RTO. If liveness also
checked the database, then during an RDS failover the kubelet would decide the
container was broken and restart it - manufacturing an outage the architecture
did not actually have, and inflating infra-b's RTO with self-inflicted damage.
Liveness answers "is this process wedged"; readiness answers "should traffic come
here". Conflating them is one of the most common ways to make a resilient system
measure as a fragile one.
"""

from __future__ import annotations

import logging
import os
import threading
import time
from contextlib import contextmanager

import psycopg
from flask import Flask, jsonify, request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest
from psycopg_pool import ConnectionPool

logging.basicConfig(
    level=logging.INFO,
    format='{"ts":"%(asctime)s","level":"%(levelname)s","msg":"%(message)s"}',
)
log = logging.getLogger("witness")

app = Flask(__name__)

def _resolve_zone() -> str:
    """Work out which AZ this pod is running in.

    Every response carries the zone, which is what lets the availability probe
    distinguish "the surviving AZs took over" from "the doomed AZ answered again".
    Without it, a 200 during the fault window is ambiguous and the whole RTO
    story rests on faith.

    Kubernetes does not expose *node* labels through the downward API - only pod
    fields - so an initContainer reads topology.kubernetes.io/zone off the node
    and drops it here. Reading it from EC2 instance metadata instead would be
    less code and more fragile: Karpenter's default EC2NodeClass sets the IMDS
    hop limit to 1 precisely to stop pods from reaching it.
    """
    zone = os.environ.get("POD_ZONE", "").strip()
    if zone:
        return zone

    zone_file = os.environ.get("ZONE_FILE", "/podinfo/zone")
    try:
        with open(zone_file, encoding="utf-8") as handle:
            return handle.read().strip() or "unknown"
    except OSError:
        return "unknown"


ZONE = _resolve_zone()
NODE = os.environ.get("NODE_NAME", "unknown")
POD = os.environ.get("POD_NAME", "unknown")

WRITES_OK = Counter("witness_writes_total", "Writes committed and acknowledged", ["zone"])
WRITES_FAIL = Counter("witness_write_failures_total", "Writes that did not commit", ["zone", "reason"])
WRITE_LATENCY = Histogram(
    "witness_write_duration_seconds",
    "Time from request to COMMIT returning",
    ["zone"],
    # Buckets are stretched out to 30s on purpose. During an RDS failover the
    # interesting latencies are 5-90s, and a default histogram topping out at
    # 10s would bucket every one of them into +Inf and tell you nothing.
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 20, 30),
)
DB_UP = Gauge("witness_db_reachable", "1 when the last DB probe succeeded", ["zone"])
LAST_SEQ = Gauge("witness_last_committed_seq", "Highest sequence number this pod has committed", ["zone"])

_pool: ConnectionPool | None = None
_seq_lock = threading.Lock()


def _dsn() -> str:
    """Build the connection string.

    The password comes from a file mounted by the Secrets Store CSI driver rather
    than an environment variable: RDS rotates the managed master secret, and an
    env var is baked in at process start and would go stale on rotation. A file
    is re-read on every connection.
    """
    host = os.environ["DB_HOST"]
    port = os.environ.get("DB_PORT", "5432")
    name = os.environ.get("DB_NAME", "resilience")
    user = os.environ.get("DB_USER", "app")

    password_file = os.environ.get("DB_PASSWORD_FILE")
    if password_file and os.path.exists(password_file):
        with open(password_file, encoding="utf-8") as handle:
            password = handle.read().strip()
    else:
        password = os.environ.get("DB_PASSWORD", "")

    # Defaults to require, matching rds.force_ssl=1 in the parameter group. It is
    # overridable only so the app can be smoke-tested against a throwaway local
    # Postgres that has no TLS - which is worth doing, because the alternative is
    # discovering a bug in the RPO instrument twenty minutes into an AWS run.
    #
    # Nothing in k8s/ ever sets DB_SSLMODE, so the deployed default stands.
    sslmode = os.environ.get("DB_SSLMODE", "require")

    return (
        f"host={host} port={port} dbname={name} user={user} password={password} "
        f"sslmode={sslmode} "
        # These three are the difference between a 90-second failover and a
        # 15-minute one. Without them, libpq inherits the kernel's TCP timeout
        # and a connection to a database that no longer exists can sit there
        # blocking for minutes. The pod would look healthy, serve nothing, and
        # the RTO would be dominated by a socket timeout rather than by AWS.
        "connect_timeout=3 "
        "keepalives=1 keepalives_idle=5 keepalives_interval=2 keepalives_count=2"
    )


def _init_pool() -> ConnectionPool:
    pool = ConnectionPool(
        conninfo=_dsn(),
        min_size=1,
        max_size=8,
        # Hand back a broken connection rather than blocking forever. During a
        # failover every pooled connection is dead; the pool must notice quickly
        # and rebuild instead of queueing requests behind dead connections.
        timeout=5,
        max_lifetime=300,
        check=ConnectionPool.check_connection,
        open=False,
    )
    pool.open()
    return pool


@contextmanager
def _connection():
    global _pool
    if _pool is None:
        with _seq_lock:
            if _pool is None:
                _pool = _init_pool()
    with _pool.connection() as conn:
        yield conn


def init_schema() -> None:
    """Create the ledger table. Idempotent: every pod runs this at startup."""
    with _connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS ledger (
                    seq         BIGINT PRIMARY KEY,
                    written_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
                    zone        TEXT NOT NULL,
                    pod         TEXT NOT NULL
                )
                """
            )
        conn.commit()
    log.info("schema ready")


@app.get("/healthz")
def healthz():
    """Liveness. Deliberately does not touch the database - see module docstring."""
    return jsonify(status="alive", zone=ZONE, pod=POD, node=NODE), 200


@app.get("/readyz")
def readyz():
    """Readiness. Fails the pod out of the Service's endpoints when the DB is gone.

    This is what makes the availability probe measure the *system*: a pod that
    cannot reach Postgres stops receiving traffic, so a request either gets a
    working pod or gets nothing. There is no third state where a request lands on
    a pod that answers 200 and then silently cannot do any work.
    """
    try:
        with _connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
        DB_UP.labels(zone=ZONE).set(1)
        return jsonify(status="ready", zone=ZONE, pod=POD), 200
    except Exception as exc:  # noqa: BLE001 - any failure means "not ready", full stop
        DB_UP.labels(zone=ZONE).set(0)
        log.warning("readiness failed: %s", exc)
        return jsonify(status="degraded", zone=ZONE, pod=POD, error=str(exc)), 503


@app.post("/write")
def write():
    """Append one sequence number and acknowledge it only once it is committed.

    The client supplies the sequence number, not the server. That is deliberate:
    the client is the one that has to reason about what it believed was durable,
    and a server-side sequence would leave a gap the client cannot interpret after
    the server has been destroyed and replaced.
    """
    payload = request.get_json(silent=True) or {}
    seq = payload.get("seq")

    if not isinstance(seq, int):
        return jsonify(error="seq must be an integer"), 400

    started = time.perf_counter()
    try:
        with _connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO ledger (seq, zone, pod) VALUES (%s, %s, %s) "
                    "ON CONFLICT (seq) DO NOTHING",
                    (seq, ZONE, POD),
                )
            # The acknowledgement below is only trustworthy because this commit
            # is synchronous. On a Multi-AZ instance it does not return until the
            # standby has the WAL record too - which is exactly why infra-b's RPO
            # is zero and infra-a's is not.
            conn.commit()

        elapsed = time.perf_counter() - started
        WRITE_LATENCY.labels(zone=ZONE).observe(elapsed)
        WRITES_OK.labels(zone=ZONE).inc()
        LAST_SEQ.labels(zone=ZONE).set(seq)

        return jsonify(seq=seq, committed=True, zone=ZONE, pod=POD, duration_s=round(elapsed, 4)), 200

    except Exception as exc:  # noqa: BLE001
        WRITES_FAIL.labels(zone=ZONE, reason=type(exc).__name__).inc()
        DB_UP.labels(zone=ZONE).set(0)
        log.error("write failed at seq=%s: %s", seq, exc)
        # 503, not 500: this is "try again elsewhere", and the client's RPO
        # bookkeeping depends on knowing this write was NOT acknowledged.
        return jsonify(seq=seq, committed=False, error=str(exc)), 503


@app.get("/last")
def last():
    """Highest sequence number the database still has.

    Called after recovery. The difference between this and the last seq the
    client saw acknowledged is the data AWS lost, and the timestamps of those two
    rows give the RPO in seconds.
    """
    try:
        with _connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT seq, written_at FROM ledger ORDER BY seq DESC LIMIT 1")
                row = cur.fetchone()
                cur.execute("SELECT count(*) FROM ledger")
                total = cur.fetchone()[0]

        if row is None:
            return jsonify(last_seq=None, row_count=0, zone=ZONE), 200

        return jsonify(
            last_seq=row[0],
            last_written_at=row[1].isoformat(),
            row_count=total,
            zone=ZONE,
            pod=POD,
        ), 200

    except Exception as exc:  # noqa: BLE001
        return jsonify(error=str(exc)), 503


@app.get("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


if __name__ == "__main__":
    # Retry the schema bootstrap: on a cold stack the pods are frequently Running
    # before RDS has finished becoming available, and crash-looping through that
    # window just adds noise to the very metrics we are trying to read.
    for attempt in range(30):
        try:
            init_schema()
            break
        except Exception as exc:  # noqa: BLE001
            log.warning("schema bootstrap attempt %s failed: %s", attempt + 1, exc)
            time.sleep(2)

    app.run(host="0.0.0.0", port=8080)
