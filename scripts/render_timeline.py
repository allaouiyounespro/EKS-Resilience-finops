#!/usr/bin/env python3
"""Draw the outage from the external probe's timeline.

owner: allaouiyounespro

    python3 scripts/render_timeline.py results/infra-a/<run>/ --out docs/outage-infra-a.svg

Why not a Grafana screenshot?

Because for infra-a, Grafana cannot tell the truth. kube-state-metrics, the
Prometheus pods and the Grafana pod all ran on system nodes inside the target AZ.
They died with it. Over a 90-minute window that contained a 15-minute total
outage, kube-state-metrics produced THREE data points. The Pending-pods panel
therefore renders zero - not because no pods were pending, but because nobody was
left alive to count them.

The external probe, running on a laptop outside the blast radius, produced 578
consecutive samples with no gap at all.

So the chart below is drawn from the probe. It is the only witness that was still
breathing, and its file is committed alongside the image, so anyone can redraw it
and check.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

W, H = 1200, 340
PAD_L, PAD_R, PAD_T, PAD_B = 70, 30, 56, 62
PLOT_W = W - PAD_L - PAD_R
PLOT_H = H - PAD_T - PAD_B

UP = "#1baf7a"
DOWN = "#e34948"
INK = "#0b0b0b"
MUTED = "#52514e"
GRID = "#d9d8d3"


def render(samples: list[dict], fault_start: float, fault_end: float, stack: str, title: str) -> str:
    t0 = samples[0]["ts"]
    t1 = samples[-1]["ts"]
    span = max(t1 - t0, 1)

    def x(ts: float) -> float:
        return PAD_L + (ts - t0) / span * PLOT_W

    parts: list[str] = []

    # One thin vertical band per sample: green if the request succeeded, red if it
    # did not. No smoothing, no aggregation, no rolling average - a rolling mean
    # would soften the very edge the RTO is measured from.
    step = PLOT_W / len(samples)
    for s in samples:
        colour = UP if s["ok"] else DOWN
        parts.append(
            f'<rect x="{x(s["ts"]):.2f}" y="{PAD_T}" width="{step + 0.6:.2f}" '
            f'height="{PLOT_H}" fill="{colour}" />'
        )

    # The fault window, drawn on top so the reader can see how much of the outage
    # happened after FIS had already finished - which for infra-a is most of it.
    fx0, fx1 = x(fault_start), x(min(fault_end, t1))
    parts.append(
        f'<rect x="{fx0:.1f}" y="{PAD_T}" width="{max(fx1 - fx0, 1):.1f}" height="{PLOT_H}" '
        f'fill="none" stroke="{INK}" stroke-width="1.5" stroke-dasharray="6 4" />'
    )
    parts.append(
        f'<text x="{(fx0 + fx1) / 2:.1f}" y="{PAD_T - 10}" text-anchor="middle" '
        f'font-size="12" font-weight="600" fill="{INK}">AWS FIS: AZ isolated ({(fault_end - fault_start) / 60:.0f} min)</text>'
    )

    # Minute ticks.
    minutes = int(span // 60)
    tick_every = max(1, minutes // 12)
    for m in range(0, minutes + 1, tick_every):
        tx = x(t0 + m * 60)
        parts.append(f'<line x1="{tx:.1f}" y1="{PAD_T + PLOT_H}" x2="{tx:.1f}" y2="{PAD_T + PLOT_H + 5}" stroke="{GRID}" />')
        parts.append(
            f'<text x="{tx:.1f}" y="{PAD_T + PLOT_H + 20}" text-anchor="middle" '
            f'font-size="11" fill="{MUTED}">{m}m</text>'
        )

    failed = sum(1 for s in samples if not s["ok"])
    availability = 1 - failed / len(samples)

    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="Segoe UI, Helvetica, Arial, sans-serif">
  <rect width="{W}" height="{H}" fill="#fcfcfb"/>
  <text x="{PAD_L}" y="24" font-size="16" font-weight="700" fill="{INK}">{title}</text>
  <text x="{PAD_L}" y="42" font-size="12" fill="{MUTED}">{len(samples)} requests, one per second, from outside the cluster &#183; each band is one request</text>

  {"".join(parts)}

  <rect x="{PAD_L}" y="{PAD_T}" width="{PLOT_W}" height="{PLOT_H}" fill="none" stroke="{GRID}"/>

  <text x="{PAD_L - 10}" y="{PAD_T + 16}" text-anchor="end" font-size="11" fill="{UP}" font-weight="600">up</text>
  <text x="{PAD_L - 10}" y="{PAD_T + PLOT_H - 6}" text-anchor="end" font-size="11" fill="{DOWN}" font-weight="600">down</text>

  <text x="{PAD_L}" y="{H - 16}" font-size="12" fill="{INK}">
    <tspan font-weight="700">{failed}</tspan><tspan fill="{MUTED}"> of {len(samples)} requests failed &#183; availability </tspan><tspan font-weight="700">{availability:.1%}</tspan>
  </text>
  <text x="{W - PAD_R}" y="{H - 16}" text-anchor="end" font-size="11" fill="{MUTED}">{stack} &#183; github.com/allaouiyounespro</text>
</svg>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description="Draw an outage timeline from a probe run")
    parser.add_argument("run_dir")
    parser.add_argument("--out", required=True)
    parser.add_argument("--title", default=None)
    args = parser.parse_args()

    run = Path(args.run_dir)
    result = json.loads((run / "result.json").read_text(encoding="utf-8"))
    samples = [json.loads(line) for line in (run / "probe.ndjson").read_text(encoding="utf-8").splitlines() if line.strip()]

    if not samples:
        print("no samples", file=sys.stderr)
        return 1

    fault_start = result["fault_start"]
    # The FIS window is 15 minutes. Everything after it is recovery - and for
    # infra-a, the recovery never arrives.
    fault_end = fault_start + 15 * 60

    stack = result["stack"]
    title = args.title or f"{stack}: a single availability zone fails"

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(render(samples, fault_start, fault_end, stack, title), encoding="utf-8")

    print(f"{out}  ({len(samples)} samples)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
