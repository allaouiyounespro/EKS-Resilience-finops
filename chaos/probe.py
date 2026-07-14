"""Availability probe. Runs OUTSIDE the cluster, on purpose.

owner: allaouiyounespro
portfolio: github.com/allaouiyounespro

    python -m chaos.probe --url http://<nlb>/readyz --out results/probe-a.ndjson

Why not just use Prometheus? Because Prometheus is inside the cluster being
destroyed. Its own scrapes fail during the fault, its WAL can gap, and if it was
scheduled in the AZ that FIS deletes it stops existing altogether. Asking a
system to report on its own death produces a suspiciously flattering obituary.

This probe runs from a laptop or a CI runner in another region. It knows nothing
about Kubernetes. It hits the public endpoint once a second and writes down what
a real user would have seen - which is the only definition of availability that
anybody outside the engineering team accepts.

It writes NDJSON, one line per second, flushed immediately. Not a summary at the
end: if the probe is killed mid-run, everything it observed up to that moment is
already durable on disk. A summary written at exit is a summary you lose exactly
when the experiment went interestingly wrong.
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


def probe_once(url: str, timeout: float) -> dict:
    """One request. Never raises - a probe that crashes on a failure is useless.

    The whole point of this function is to run during an outage, so every failure
    mode it can hit is an expected observation, not an error: connection refused,
    DNS failure, timeout, 503 from a pod that cannot reach the database. Each one
    is recorded as ok=false with the reason, and the loop carries on.
    """
    started = time.time()

    try:
        request = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read(4096)
            elapsed_ms = (time.time() - started) * 1000

            zone = None
            try:
                zone = json.loads(body).get("zone")
            except (json.JSONDecodeError, AttributeError):
                pass

            return {
                "ts": started,
                "ok": 200 <= response.status < 300,
                "status": response.status,
                "zone": zone,
                "latency_ms": round(elapsed_ms, 2),
            }

    except urllib.error.HTTPError as exc:
        # A 503 from a pod whose database is gone. The service answered, and the
        # answer was "no" - which is a failure, but a well-behaved one, and worth
        # distinguishing in the log from a connection that went nowhere.
        return {
            "ts": started,
            "ok": False,
            "status": exc.code,
            "zone": None,
            "latency_ms": round((time.time() - started) * 1000, 2),
            "error": f"http_{exc.code}",
        }

    except Exception as exc:  # noqa: BLE001 - timeouts, DNS, refused, reset: all just "down"
        return {
            "ts": started,
            "ok": False,
            "status": None,
            "zone": None,
            "latency_ms": round((time.time() - started) * 1000, 2),
            "error": type(exc).__name__,
        }


def main() -> int:
    parser = argparse.ArgumentParser(description="External availability probe")
    parser.add_argument("--url", required=True, help="Endpoint to probe, e.g. http://<nlb>/readyz")
    parser.add_argument("--out", required=True, help="NDJSON output path")
    parser.add_argument(
        "--interval",
        type=float,
        default=1.0,
        help="Seconds between probes. This is the resolution floor on the reported RTO: "
        "at 1s you cannot honestly claim to have measured a 400ms outage.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=3.0,
        help="Per-request timeout. Kept below the interval so a hung request cannot "
        "stall the probe and silently punch a hole in the timeline - a gap in the "
        "samples would be read by the analysis as time that simply did not exist.",
    )
    parser.add_argument("--duration", type=float, default=0, help="Seconds to run. 0 = until interrupted.")
    args = parser.parse_args()

    if args.timeout >= args.interval:
        print(
            f"warning: timeout ({args.timeout}s) >= interval ({args.interval}s). "
            "Slow responses will stretch the sampling period and distort the timeline.",
            file=sys.stderr,
        )

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    started = time.time()
    count = 0
    failures = 0

    print(f"probing {args.url} every {args.interval}s -> {out_path}", file=sys.stderr)

    with out_path.open("w", encoding="utf-8") as handle:
        while _running:
            if args.duration and (time.time() - started) >= args.duration:
                break

            tick = time.time()
            sample = probe_once(args.url, args.timeout)

            handle.write(json.dumps(sample) + "\n")
            # Flush every line. The process may be killed at any moment - by the
            # operator, by the CI runner's timeout, by a laptop lid closing - and
            # buffered samples would be lost precisely when the run was most
            # interesting.
            handle.flush()

            count += 1
            if not sample["ok"]:
                failures += 1

            if count % 30 == 0:
                print(
                    f"  {count} samples, {failures} failures, "
                    f"last={'OK' if sample['ok'] else sample.get('error') or sample.get('status')}",
                    file=sys.stderr,
                )

            # Sleep for the remainder of the interval rather than a flat interval:
            # otherwise every slow response permanently shifts the sampling clock,
            # and 900 samples in the timeline no longer means 900 seconds.
            elapsed = time.time() - tick
            if (remaining := args.interval - elapsed) > 0:
                time.sleep(remaining)

    print(f"done: {count} samples, {failures} failures -> {out_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
