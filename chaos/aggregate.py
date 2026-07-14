"""Combine several runs of one architecture into a defensible number.

owner: allaouiyounespro
portfolio: github.com/allaouiyounespro

    python3 -m chaos.aggregate --stack infra-b results/infra-b/*/result.json

One run is an anecdote. RDS failover time varies by tens of seconds between
runs, Karpenter's node launch depends on whatever capacity EC2 happens to have
that minute, and a single number from a single run is a coin flip presented as a
measurement.

So the campaign runs each architecture three times and reports a median.

Two decisions in here are worth defending, because both are places where it
would be easy to produce a nicer-looking number:

**We take the median.** A single run that never recovered, or one that hit a slow
failover, would drag a mean somewhere no individual run ever was. The median is
a value the system actually produced.

**A run that never recovered stays in the count.** It has no RTO - there is nothing
to average - but silently excluding it would report "infra-a recovers in 22
minutes" from a set of runs where one never recovered at all. That is the single
most dishonest thing this file could do. Instead, non-recovery is counted, and
if it is the majority outcome the aggregate refuses to report an RTO and says so.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Aggregate:
    stack: str
    runs: int

    rto_median: float | None
    rto_min: float | None
    rto_max: float | None
    rto_spread: float | None
    runs_recovered: int
    runs_never_recovered: int
    runs_survived: int

    rpo_median: float | None
    rpo_max: float | None
    runs_with_data_loss: int
    lost_writes_max: int

    availability_median: float

    def summary(self) -> str:
        lines = [f"{self.stack}: {self.runs} run(s)"]

        if self.runs_survived == self.runs:
            lines.append("  RTO  0s - every run survived without a single failed request")
        elif self.rto_median is None:
            lines.append(
                f"  RTO  NOT MEASURABLE - {self.runs_never_recovered}/{self.runs} runs never "
                f"recovered inside the observation window"
            )
        else:
            lines.append(
                f"  RTO  median {self.rto_median:.0f}s "
                f"(min {self.rto_min:.0f}s, max {self.rto_max:.0f}s, spread {self.rto_spread:.0f}s)"
            )
            if self.runs_never_recovered:
                lines.append(
                    f"       WARNING: {self.runs_never_recovered}/{self.runs} run(s) never recovered "
                    f"and are excluded from the median above - the true figure is worse"
                )

        if self.rpo_median is None or not self.runs_with_data_loss:
            lines.append("  RPO  0s - no acknowledged write was ever lost")
        else:
            lines.append(
                f"  RPO  median {self.rpo_median:.0f}s (worst {self.rpo_max:.0f}s), "
                f"data loss in {self.runs_with_data_loss}/{self.runs} run(s), "
                f"up to {self.lost_writes_max} acknowledged write(s) lost"
            )

        lines.append(f"  availability  median {self.availability_median:.2%} during the fault window")
        return "\n".join(lines)


def aggregate(results: list[dict], stack: str) -> Aggregate:
    if not results:
        raise ValueError("no results to aggregate")

    rtos = [r["rto"] for r in results]
    rpos = [r["rpo"] for r in results]

    survived = sum(1 for r in rtos if r.get("survived"))
    never_recovered = sum(1 for r in rtos if not r.get("recovered"))

    # Only runs that actually recovered contribute an RTO. Runs that survived
    # contribute a genuine 0; runs that never recovered contribute nothing, and
    # are reported separately rather than being quietly dropped.
    measurable = [
        float(r["seconds"])
        for r in rtos
        if r.get("recovered") and r.get("seconds") is not None
    ]

    if measurable:
        rto_median = statistics.median(measurable)
        rto_min, rto_max = min(measurable), max(measurable)
        rto_spread = rto_max - rto_min
    else:
        rto_median = rto_min = rto_max = rto_spread = None

    # If more runs failed to recover than recovered, a median over the survivors
    # is not a description of the system - it is a description of its luckiest
    # days. Refuse.
    if never_recovered > len(measurable):
        rto_median = rto_min = rto_max = rto_spread = None

    losses = [float(r["seconds"]) for r in rpos if r.get("data_loss") and r.get("seconds") is not None]
    rpo_median = statistics.median(losses) if losses else None
    rpo_max = max(losses) if losses else None

    availabilities = [float(r["availability"]) for r in rtos]

    return Aggregate(
        stack=stack,
        runs=len(results),
        rto_median=rto_median,
        rto_min=rto_min,
        rto_max=rto_max,
        rto_spread=rto_spread,
        runs_recovered=len(measurable),
        runs_never_recovered=never_recovered,
        runs_survived=survived,
        rpo_median=rpo_median,
        rpo_max=rpo_max,
        runs_with_data_loss=sum(1 for r in rpos if r.get("data_loss")),
        lost_writes_max=max((int(r.get("lost_writes", 0)) for r in rpos), default=0),
        availability_median=statistics.median(availabilities),
    )


def markdown_table(agg: Aggregate) -> str:
    """The block that gets pasted into docs/results.md."""

    def fmt_seconds(value: float | None) -> str:
        if value is None:
            return "**never recovered**"
        if value == 0:
            return "0 s"
        if value < 90:
            return f"{value:.0f} s"
        return f"{value:.0f} s ({value / 60:.1f} min)"

    rows = [
        f"| Runs | {agg.runs} |",
        f"| RTO (median) | {fmt_seconds(agg.rto_median)} |",
    ]

    if agg.rto_min is not None and agg.rto_spread:
        rows.append(f"| RTO (min – max) | {fmt_seconds(agg.rto_min)} – {fmt_seconds(agg.rto_max)} |")

    rows += [
        f"| RPO (median) | {fmt_seconds(agg.rpo_median) if agg.rpo_median else '0 s'} |",
        f"| Availability during fault (median) | {agg.availability_median:.2%} |",
        f"| Acknowledged writes lost (worst run) | {agg.lost_writes_max} |",
        f"| Runs that never recovered | {agg.runs_never_recovered} / {agg.runs} |",
    ]

    return "\n".join(["| metric | value |", "|---|---|", *rows])


def main() -> int:
    parser = argparse.ArgumentParser(description="Aggregate several experiment runs into a median")
    parser.add_argument("--stack", required=True)
    parser.add_argument("results", nargs="+", help="result.json files from each run")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--markdown", action="store_true", help="Emit the docs/results.md table")
    parser.add_argument("--out", default=None)
    args = parser.parse_args()

    loaded = []
    for path in args.results:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        if data.get("stack") != args.stack:
            # Mixing two architectures' runs into one median would be a
            # spectacular own goal, and the filenames make it easy to do by
            # accident with a careless glob.
            print(
                f"refusing to aggregate: {path} is from stack {data.get('stack')!r}, not {args.stack!r}",
                file=sys.stderr,
            )
            return 1
        loaded.append(data)

    agg = aggregate(loaded, args.stack)

    if args.json:
        print(json.dumps(agg.__dict__, indent=2))
    elif args.markdown:
        print(markdown_table(agg))
    else:
        print()
        print(agg.summary())
        print()

    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(agg.__dict__, indent=2) + "\n", encoding="utf-8")
        print(f"  written to {out}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
