"""Durability probe: the RPO instrument.

owner: allaouiyounespro
portfolio: github.com/allaouiyounespro

    python -m chaos.writer --url http://<nlb> --out results/acks-a.ndjson

Writes a monotonically increasing sequence number once a second and records
exactly which ones came back acknowledged. Afterwards, GET /last says what the
database still has. The gap between those two facts is data that AWS lost, and
the timestamps turn that gap into an RPO in seconds.

The single design rule this file exists to enforce: **only record an ack after
the server said it committed.** Never optimistically, never on a timeout, never
on a connection error. If we cannot prove a write was durable, it does not go in
the ledger as durable.

That rule is what makes an RPO of 0 a *finding* rather than an assertion. Anyone
can claim Multi-AZ gives RPO=0; this measures whether it actually did, and it can
only do that if the measuring instrument is stricter than the thing it measures.
"""

from __future__ import annotations

import argparse
import json
import signal
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

_running = True


def _stop(signum, frame):  # noqa: ARG001
    global _running
    _running = False


def write_once(base_url: str, seq: int, timeout: float) -> dict:
    """POST one sequence number. Returns a record of what we can actually prove.

    Note the three-way outcome, which is the crux of the whole measurement:

      committed=True   the server said COMMIT returned. Durable, we can hold AWS
                       to this one.
      committed=False  the server said 503. Never promised, so its absence later
                       is not data loss.
      committed=False  the request timed out or the connection died. We DO NOT
                       KNOW whether it committed - and the honest thing to do
                       with an unknown is to not count it as a promise. Counting
                       it would risk reporting data loss that never happened.
    """
    started = time.time()
    payload = json.dumps({"seq": seq}).encode("utf-8")

    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/write",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = json.loads(response.read(4096))
            return {
                "seq": seq,
                "ts": started,
                # Trust the server's own word, and only that. A 200 whose body
                # says committed=false is not an acknowledgement, however green
                # the status code looks.
                "committed": bool(body.get("committed")) and 200 <= response.status < 300,
                "zone": body.get("zone"),
                "duration_s": body.get("duration_s"),
            }

    except urllib.error.HTTPError as exc:
        return {"seq": seq, "ts": started, "committed": False, "error": f"http_{exc.code}"}

    except Exception as exc:  # noqa: BLE001
        return {"seq": seq, "ts": started, "committed": False, "error": type(exc).__name__}


def read_last(base_url: str, timeout: float = 10.0) -> int | None:
    """GET /last. The database's own account of what survived.

    Called after recovery. Returns None if the database is still unreachable,
    which for infra-a is a perfectly plausible end state and must not be confused
    with "the database is empty".
    """
    request = urllib.request.Request(f"{base_url.rstrip('/')}/last", method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = json.loads(response.read(4096))
            return body.get("last_seq")
    except Exception:  # noqa: BLE001
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description="Durability probe (RPO instrument)")
    parser.add_argument("--url", required=True, help="Base URL of the witness service")
    parser.add_argument("--out", required=True, help="NDJSON output path")
    parser.add_argument("--interval", type=float, default=1.0, help="Seconds between writes. This is the granularity floor on the reported RPO.")
    parser.add_argument("--timeout", type=float, default=5.0, help="Per-write timeout. Longer than the probe's, because a Multi-AZ commit legitimately blocks for seconds during a failover and we do not want to record a false 'not committed' for a write that was in fact fine.")
    parser.add_argument("--duration", type=float, default=0, help="Seconds to run. 0 = until interrupted.")
    parser.add_argument("--start-seq", type=int, default=1, help="First sequence number.")
    args = parser.parse_args()

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    started = time.time()
    seq = args.start_seq
    acked = 0
    rejected = 0

    print(f"writing to {args.url}/write every {args.interval}s -> {out_path}", file=sys.stderr)

    with out_path.open("w", encoding="utf-8") as handle:
        while _running:
            if args.duration and (time.time() - started) >= args.duration:
                break

            tick = time.time()
            record = write_once(args.url, seq, args.timeout)

            handle.write(json.dumps(record) + "\n")
            handle.flush()

            if record["committed"]:
                acked += 1
            else:
                rejected += 1

            if seq % 30 == 0:
                print(f"  seq={seq} acked={acked} rejected={rejected}", file=sys.stderr)

            seq += 1

            elapsed = time.time() - tick
            if (remaining := args.interval - elapsed) > 0:
                time.sleep(remaining)

    last_seq = read_last(args.url)

    print(f"done: {acked} acknowledged, {rejected} rejected", file=sys.stderr)
    print(f"database reports last_seq={last_seq}", file=sys.stderr)

    if last_seq is None:
        print("  database unreachable - RPO cannot be established until it returns", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
