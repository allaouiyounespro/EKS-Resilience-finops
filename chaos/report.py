"""Turn one experiment's raw timelines into the reported result.

owner: allaouiyounespro
portfolio: github.com/allaouiyounespro

    python -m chaos.report \
        --stack infra-a \
        --probe results/infra-a/probe.ndjson \
        --acks  results/infra-a/acks.ndjson \
        --fault-start 1752480000 \
        --db-last-seq 412 \
        --out results/infra-a/result.json

Deliberately separate from the probes: the probes capture, this interprets, and
the raw NDJSON is never overwritten. Any claim in the final report can be
re-derived from the timelines by someone who does not trust this code - which is
the only reason anyone should believe the numbers.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from chaos.analysis import DEFAULT_STABILITY_RUN, compute_rpo, compute_rto, load_acks, load_samples


def _iso(ts: float | None) -> str | None:
    if ts is None:
        return None
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()


def main() -> int:
    parser = argparse.ArgumentParser(description="Compute RTO and RPO for one experiment run")
    parser.add_argument("--stack", required=True, help="infra-a or infra-b")
    parser.add_argument("--probe", required=True, help="Availability timeline (NDJSON)")
    parser.add_argument("--acks", required=True, help="Write acknowledgement timeline (NDJSON)")
    parser.add_argument(
        "--fault-start",
        type=float,
        required=True,
        help="Unix timestamp at which FIS actually began injecting. Taken from the experiment's "
        "own startTime, not from when the operator pressed enter - the gap between the two is "
        "routinely 10-20s of API latency and charging it to the architecture would be dishonest.",
    )
    parser.add_argument(
        "--db-last-seq",
        type=int,
        default=None,
        help="Highest sequence number the database still has after recovery, from GET /last. "
        "Omit if the database never came back - the report will say so rather than guess.",
    )
    parser.add_argument("--stability-run", type=int, default=DEFAULT_STABILITY_RUN)
    parser.add_argument("--out", default=None, help="Write the result as JSON here.")
    args = parser.parse_args()

    samples = load_samples(args.probe)
    acks = load_acks(args.acks)

    rto = compute_rto(samples, args.fault_start, stability_run=args.stability_run)
    rpo = compute_rpo(acks, args.db_last_seq)

    result = {
        "stack": args.stack,
        "fault_start": args.fault_start,
        "fault_start_iso": _iso(args.fault_start),
        "rto": {
            "seconds": rto.rto_seconds,
            "outage_start_iso": _iso(rto.outage_start),
            "recovered_at_iso": _iso(rto.recovered_at),
            "detection_seconds": rto.detection_seconds,
            "availability": rto.availability,
            "total_samples": rto.total_samples,
            "failed_samples": rto.failed_samples,
            "zones_serving_during_fault": rto.zones_seen_during_fault,
            "survived": rto.survived,
            "recovered": rto.recovered,
        },
        "rpo": {
            "seconds": rpo.rpo_seconds,
            "lost_writes": rpo.lost_writes,
            "data_loss": rpo.data_loss,
            "unknown": rpo.unknown,
            "last_acked_seq": rpo.last_acked_seq,
            "db_last_seq": rpo.db_last_seq,
        },
    }

    print(f"\n=== {args.stack} ===")
    print(f"  {rto.summary()}")
    print(f"  {rpo.summary()}")

    # The zone list is the sanity check that the experiment actually did what it
    # claimed. If the fault targeted eu-west-3a and eu-west-3a still appears here
    # as serving traffic throughout, the fault did not land - and the RTO of 0
    # that would otherwise be reported as a triumph is in fact a broken run.
    if rto.zones_seen_during_fault:
        print(f"  zones serving during the fault: {', '.join(rto.zones_seen_during_fault)}")
    else:
        print("  zones serving during the fault: none")

    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(f"\n  written to {out_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
