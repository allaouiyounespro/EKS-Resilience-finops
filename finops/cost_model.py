"""What each architecture costs, and how often an AZ must fail to justify the difference.

owner: allaouiyounespro
portfolio: github.com/allaouiyounespro

    python3 -m finops.cost_model
    python3 -m finops.cost_model --revenue-per-hour 20000 --incidents-per-year 4

The comparison is only worth anything because both architectures are priced from
the SAME price list and the SAME line-item model. Every difference in the output
traces back to a difference in the deployed shape, never to a difference in how
the two were counted.

The headline question this answers:

    infra-b costs an extra D dollars a month. An AZ failure costs infra-a an
    outage of length T. How often must that happen before the extra D is the
    cheaper of the two?

That is a break-even, and it has a real answer once you supply one business
number - what an hour of downtime costs. Everything else here is arithmetic on
AWS's price list.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

PRICING_PATH = Path(__file__).parent / "pricing.yaml"
SHAPES_PATH = Path(__file__).parent / "shapes.yaml"


@dataclass
class LineItem:
    """One billable thing, and why it exists."""

    name: str
    monthly: float
    detail: str = ""
    resilience_driven: bool = False  # True if this line exists *because of* the HA decision


@dataclass
class CostBreakdown:
    stack: str
    items: list[LineItem] = field(default_factory=list)

    @property
    def total(self) -> float:
        return sum(item.monthly for item in self.items)

    @property
    def resilience_premium(self) -> float:
        """The slice of the bill that buys resilience and nothing else.

        Useful because it is the number to defend in the room. "We spend 380 a
        month" invites a haircut; "we spend 180 to run it and 200 to survive an
        AZ failure, here is the measured RTO with and without" is an argument.
        """
        return sum(item.monthly for item in self.items if item.resilience_driven)

    def table(self) -> str:
        width = max((len(i.name) for i in self.items), default=10) + 2
        lines = [f"{'line item':<{width}} {'USD/month':>10}  note"]
        lines.append("-" * (width + 12 + 40))
        for item in sorted(self.items, key=lambda i: -i.monthly):
            marker = " *" if item.resilience_driven else "  "
            lines.append(f"{item.name:<{width}} {item.monthly:>10.2f}{marker} {item.detail}")
        lines.append("-" * (width + 12 + 40))
        lines.append(f"{'TOTAL':<{width}} {self.total:>10.2f}")
        lines.append("")
        lines.append("* = exists only because of the high-availability decision")
        return "\n".join(lines)


def load_yaml(path: Path) -> dict[str, Any]:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def _hourly_to_monthly(hourly: float, hours: int) -> float:
    return hourly * hours


def compute_cost(shape: dict[str, Any], pricing: dict[str, Any], stack_name: str = "") -> CostBreakdown:
    """Price one architecture, line by line.

    `shape` is the finops_inputs object from Terraform (or its mirror in
    shapes.yaml). `resilience_driven` marks the lines that would disappear if the
    HA decision were reversed - that flag is the whole point of the exercise.
    """
    hours = pricing["meta"]["hours_per_month"]
    compute = pricing["compute"]
    storage = pricing["storage"]
    network = pricing["network"]
    database = pricing["database"]
    other = pricing["other"]

    breakdown = CostBreakdown(stack=stack_name or shape.get("stack", "unknown"))
    multi_az = bool(shape.get("db_multi_az", False))
    az_count = int(shape.get("workload_az_count", 1))

    # -- control plane ------------------------------------------------------
    # Identical in both. The largest line item the resilience decision cannot
    # touch, which is worth internalising before optimising anything else.
    breakdown.items.append(
        LineItem(
            "EKS control plane",
            _hourly_to_monthly(compute["eks_cluster_hourly"], hours),
            "fixed; identical in both architectures",
        )
    )

    # -- system node group --------------------------------------------------
    node_type = shape["node_instance_type"]
    node_count = int(shape["node_desired_count"])
    node_hourly = compute["ec2_hourly"][node_type]

    # Only the nodes beyond the first two are resilience-driven. infra-a needs two
    # for the system tier to survive a single node dying; the third exists purely
    # so that Karpenter survives an AZ dying.
    baseline_nodes = min(node_count, 2)
    ha_nodes = max(0, node_count - 2)

    breakdown.items.append(
        LineItem(
            "EC2 system nodes",
            _hourly_to_monthly(node_hourly, hours) * baseline_nodes,
            f"{baseline_nodes} x {node_type}",
        )
    )
    if ha_nodes:
        breakdown.items.append(
            LineItem(
                "EC2 system nodes (HA)",
                _hourly_to_monthly(node_hourly, hours) * ha_nodes,
                f"{ha_nodes} x {node_type}; keeps Karpenter alive through the AZ failure",
                resilience_driven=True,
            )
        )

    # -- Karpenter application capacity -------------------------------------
    kp_type = shape["karpenter_instance_type"]
    kp_count = int(shape["karpenter_node_count"])
    kp_hourly = compute["ec2_hourly"][kp_type]

    # The workload fits on one node. Any node beyond the first exists to spread
    # the pods across failure domains rather than to carry load.
    kp_baseline = min(kp_count, 1)
    kp_ha = max(0, kp_count - 1)

    breakdown.items.append(
        LineItem(
            "EC2 Karpenter nodes",
            _hourly_to_monthly(kp_hourly, hours) * kp_baseline,
            f"{kp_baseline} x {kp_type}",
        )
    )
    if kp_ha:
        breakdown.items.append(
            LineItem(
                "EC2 Karpenter nodes (HA)",
                _hourly_to_monthly(kp_hourly, hours) * kp_ha,
                f"{kp_ha} x {kp_type}; spreads the workload across AZs",
                resilience_driven=True,
            )
        )

    # -- EBS ----------------------------------------------------------------
    ebs_gb = (node_count * int(shape["node_disk_gb"])) + (kp_count * int(shape["karpenter_disk_gb"]))
    breakdown.items.append(
        LineItem(
            "EBS gp3",
            ebs_gb * storage["ebs_gp3_per_gb_month"],
            f"{ebs_gb} GiB of root volumes",
        )
    )

    # -- Prometheus volumes -------------------------------------------------
    # Modelled explicitly because they were missing, and a cost model with a hole
    # in it is a cost model that gets believed and then contradicted by the bill.
    prom_pvcs = int(shape.get("prometheus_pvc_count", 0))
    prom_gb = float(shape.get("prometheus_pvc_gb", 0))

    if prom_pvcs:
        baseline_pvc = min(prom_pvcs, 1)
        ha_pvc = max(0, prom_pvcs - 1)

        breakdown.items.append(
            LineItem(
                "EBS gp3 (Prometheus)",
                baseline_pvc * prom_gb * storage["ebs_gp3_per_gb_month"],
                f"{baseline_pvc} x {prom_gb:.0f} GiB",
            )
        )
        if ha_pvc:
            breakdown.items.append(
                LineItem(
                    "EBS gp3 (Prometheus HA)",
                    ha_pvc * prom_gb * storage["ebs_gp3_per_gb_month"],
                    "second replica in another AZ; an EBS volume cannot follow its pod across zones",
                    resilience_driven=True,
                )
            )

    # -- NAT ----------------------------------------------------------------
    nat_count = int(shape["nat_gateway_count"])
    nat_hourly_cost = _hourly_to_monthly(network["nat_gateway_hourly"], hours)
    nat_data_cost = float(shape.get("nat_data_gb", 0)) * network["nat_data_per_gb"]

    breakdown.items.append(
        LineItem(
            "NAT Gateway",
            nat_hourly_cost + nat_data_cost,
            "1 gateway + data processing",
        )
    )
    if nat_count > 1:
        breakdown.items.append(
            LineItem(
                "NAT Gateway (HA)",
                nat_hourly_cost * (nat_count - 1),
                f"{nat_count - 1} extra; egress survives losing an AZ",
                resilience_driven=True,
            )
        )

    # -- load balancer ------------------------------------------------------
    alb_count = int(shape.get("alb_count", 1))
    breakdown.items.append(
        LineItem(
            "Application Load Balancer",
            alb_count
            * (
                _hourly_to_monthly(network["alb_hourly"], hours)
                + _hourly_to_monthly(network["alb_lcu_hourly"], hours) * float(shape.get("alb_lcu_average", 1))
            ),
            f"{alb_count} ALB + LCU (created by the LB Controller from the Gateway)",
        )
    )

    # -- cross-AZ traffic ---------------------------------------------------
    cross_az_gb = float(shape.get("cross_az_traffic_gb", 0))
    if cross_az_gb:
        breakdown.items.append(
            LineItem(
                "Cross-AZ data transfer",
                cross_az_gb * network["cross_az_per_gb"],
                f"{cross_az_gb:.0f} GB; the toll for spreading across {az_count} AZs",
                resilience_driven=True,
            )
        )

    # -- database -----------------------------------------------------------
    db_class = shape["db_instance_class"]
    db_hourly = database["rds_hourly"][db_class]
    db_storage_gb = float(shape["db_storage_gb"])

    db_base = _hourly_to_monthly(db_hourly, hours)
    db_storage_base = db_storage_gb * database["rds_gp3_per_gb_month"]

    breakdown.items.append(LineItem("RDS instance", db_base, f"1 x {db_class}"))
    breakdown.items.append(LineItem("RDS storage", db_storage_base, f"{db_storage_gb:.0f} GiB gp3"))

    if multi_az:
        # Exactly 2x, not "about 2x": AWS runs a full standby and bills it as a
        # second instance, storage included. This one line is the price of RPO=0.
        multiplier = database["multi_az_multiplier"] - 1.0
        breakdown.items.append(
            LineItem(
                "RDS Multi-AZ standby",
                (db_base + db_storage_base) * multiplier,
                "synchronous standby; this is what buys RPO = 0",
                resilience_driven=True,
            )
        )

    if shape.get("db_read_replica"):
        breakdown.items.append(
            LineItem(
                "RDS read replica",
                db_base + db_storage_base,
                "async; the promotion path for a regional event",
                resilience_driven=True,
            )
        )

    # Backups are free up to 100% of allocated storage. Modelled rather than
    # skipped, because pushing retention past that threshold is an easy way to
    # add cost that nobody notices.
    backup_gb = db_storage_gb  # a week of a low-churn DB stays under the allocation
    free_gb = db_storage_gb * database["rds_backup_free_ratio"]
    billable_backup = max(0.0, backup_gb - free_gb)
    if billable_backup:
        breakdown.items.append(
            LineItem(
                "RDS backup storage",
                billable_backup * database["rds_backup_per_gb_month"],
                f"{billable_backup:.0f} GiB beyond the free allocation",
            )
        )

    # -- everything else ----------------------------------------------------
    breakdown.items.append(
        LineItem(
            "Secrets Manager",
            int(shape.get("secrets_count", 1)) * other["secrets_manager_per_secret_month"],
            "RDS-managed master credentials",
        )
    )

    logs_gb = float(shape.get("cloudwatch_logs_gb", 0))
    if logs_gb:
        breakdown.items.append(
            LineItem(
                "CloudWatch Logs",
                logs_gb * other["cloudwatch_logs_ingest_per_gb"],
                f"{logs_gb:.0f} GB/month ingested (control plane, FIS, flow logs)",
            )
        )

    return breakdown


# ---------------------------------------------------------------------------
# Break-even
# ---------------------------------------------------------------------------


@dataclass
class BreakEven:
    monthly_delta: float
    annual_delta: float
    downtime_cost_per_incident: float
    incidents_per_year_to_break_even: float
    incidents_per_quarter_to_break_even: float

    def summary(self) -> str:
        return (
            f"infra-b costs an extra {self.annual_delta:,.0f} USD/year.\n"
            f"One AZ failure costs infra-a {self.downtime_cost_per_incident:,.0f} USD.\n"
            f"Break-even: {self.incidents_per_year_to_break_even:.2f} incidents/year "
            f"({self.incidents_per_quarter_to_break_even:.2f} per quarter)."
        )


def downtime_cost(
    rto_seconds: float,
    revenue_per_hour: float,
    engineer_count: int = 3,
    engineer_hourly_cost: float = 120.0,
    reputational_multiplier: float = 1.0,
) -> float:
    """What one outage of length `rto_seconds` actually costs.

    Three terms, and the third is where honest models and dishonest ones diverge:

      lost revenue     the easy one, and the only one most people count
      engineer time    the people who stopped doing their jobs to fix it. Real
                       money, and it is spent whether or not revenue was lost.
      reputational     a multiplier, defaulting to 1.0 (i.e. off).

    The multiplier defaults to OFF on purpose. It is the term that lets anyone
    justify any amount of spend by asserting a large enough number, and a
    business case that depends on it is not a business case. If you turn it on,
    you own the number - so the model makes you type it in rather than smuggling
    it in as a default.
    """
    if rto_seconds < 0:
        raise ValueError("rto_seconds cannot be negative")

    hours = rto_seconds / 3600.0

    lost_revenue = hours * revenue_per_hour
    engineering = hours * engineer_count * engineer_hourly_cost

    return (lost_revenue + engineering) * reputational_multiplier


def revenue_for_target_break_even(
    monthly_delta: float,
    rto_a_seconds: float,
    rto_b_seconds: float,
    target_incidents_per_year: float,
    engineer_count: int = 3,
    engineer_hourly_cost: float = 120.0,
) -> float:
    """Invert the break-even: what must an hour of downtime be worth for the spend
    to be justified at exactly `target_incidents_per_year`?

    This exists because the break-even is quoted backwards in almost every
    resilience business case. People assert "it pays for itself at one incident a
    quarter" without noticing that this claim is not a property of the
    architecture at all - it is a statement about how much money the business
    loses per hour, and it is *only* true for one particular value of that.

    Running the model in this direction forces the assumption into the open:
    instead of asserting the conclusion, you get told what you must believe about
    your own revenue for the conclusion to hold. Then you can check whether you
    actually believe it.

    Solving:
        annual_delta = target_incidents * (cost_a(revenue) - cost_b(revenue))

    where cost(revenue) = hours * (revenue + engineers * engineer_cost).
    The engineering term is independent of revenue, so this rearranges cleanly.
    """
    if target_incidents_per_year <= 0:
        raise ValueError("target_incidents_per_year must be positive")

    delta_hours = (rto_a_seconds - rto_b_seconds) / 3600.0
    if delta_hours <= 0:
        raise ValueError(
            "infra-b's RTO is not shorter than infra-a's - there is no saving to justify, at any revenue"
        )

    annual_delta = monthly_delta * 12.0

    # required saving per incident, from the target rate
    required_saving = annual_delta / target_incidents_per_year

    # required_saving = delta_hours * (revenue + engineers * engineer_cost)
    engineering_term = engineer_count * engineer_hourly_cost
    revenue = (required_saving / delta_hours) - engineering_term

    return revenue


def break_even(
    monthly_delta: float,
    cost_per_incident: float,
) -> BreakEven:
    """How many incidents a year justify the extra spend.

    Solving:  annual_delta = incidents_per_year * cost_per_incident

    An incident rate ABOVE this number means infra-b is the cheaper architecture,
    which is the finding people find counter-intuitive: the expensive one saves
    money, provided the thing it protects against actually happens often enough.
    """
    annual_delta = monthly_delta * 12.0

    if cost_per_incident <= 0:
        raise ValueError("cost_per_incident must be positive - a free outage justifies no spend")

    incidents = annual_delta / cost_per_incident

    return BreakEven(
        monthly_delta=monthly_delta,
        annual_delta=annual_delta,
        downtime_cost_per_incident=cost_per_incident,
        incidents_per_year_to_break_even=incidents,
        incidents_per_quarter_to_break_even=incidents / 4.0,
    )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description="Cost and break-even model for the two architectures")
    parser.add_argument("--pricing", default=str(PRICING_PATH))
    parser.add_argument("--shapes", default=str(SHAPES_PATH))
    parser.add_argument(
        "--revenue-per-hour",
        type=float,
        default=5000.0,
        help="Revenue lost per hour of total outage. THE input the whole analysis pivots on - "
        "supply your own, the default is a placeholder for a mid-size SaaS.",
    )
    parser.add_argument(
        "--rto-a",
        type=float,
        default=None,
        help="Measured RTO for infra-a in seconds. Defaults to the value observed in the documented run.",
    )
    parser.add_argument("--rto-b", type=float, default=None, help="Measured RTO for infra-b in seconds.")
    parser.add_argument("--engineers", type=int, default=3)
    parser.add_argument("--engineer-hourly-cost", type=float, default=120.0)
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of a table.")
    args = parser.parse_args()

    pricing = load_yaml(Path(args.pricing))
    shapes = load_yaml(Path(args.shapes))

    cost_a = compute_cost(shapes["infra-a"], pricing, "infra-a")
    cost_b = compute_cost(shapes["infra-b"], pricing, "infra-b")

    # ------------------------------------------------------------------
    # RTO defaults: MODELLED, NOT MEASURED.
    #
    # These are the values the architecture predicts, derived from the documented
    # behaviour of each component (RDS failover 60-120s; Karpenter node launch
    # plus kubelet join 40-90s; AZ restoration, for infra-a, entirely at AWS's
    # discretion). They are placeholders so the model runs end-to-end before a
    # single dollar is spent on AWS.
    #
    # They are NOT experiment results, and nothing in this repo will present them
    # as such. Run scripts/run-experiment.sh against both stacks and pass the
    # real numbers in via --rto-a / --rto-b. docs/results.md is a template with
    # empty cells for exactly that reason - a resilience portfolio whose headline
    # numbers were invented is worth less than no portfolio at all.
    # ------------------------------------------------------------------
    rto_a = args.rto_a if args.rto_a is not None else 1_920.0
    rto_b = args.rto_b if args.rto_b is not None else 94.0
    measured = args.rto_a is not None and args.rto_b is not None

    incident_cost_a = downtime_cost(
        rto_a, args.revenue_per_hour, args.engineers, args.engineer_hourly_cost
    )
    incident_cost_b = downtime_cost(
        rto_b, args.revenue_per_hour, args.engineers, args.engineer_hourly_cost
    )

    # What you save per incident is the DIFFERENCE between the two, and it is
    # infra-b is not free during an AZ failure - it still degrades for 94 seconds.
    # Crediting it with the entire avoided outage would overstate the case, and an
    # overstated business case is one a CFO gets to demolish in front of everyone.
    saving_per_incident = incident_cost_a - incident_cost_b

    delta = cost_b.total - cost_a.total
    be = break_even(delta, saving_per_incident)

    if args.json:
        print(
            json.dumps(
                {
                    "infra_a": {"total": round(cost_a.total, 2), "resilience_premium": round(cost_a.resilience_premium, 2)},
                    "infra_b": {"total": round(cost_b.total, 2), "resilience_premium": round(cost_b.resilience_premium, 2)},
                    "monthly_delta": round(delta, 2),
                    "annual_delta": round(be.annual_delta, 2),
                    "rto_a_seconds": rto_a,
                    "rto_b_seconds": rto_b,
                    "incident_cost_a": round(incident_cost_a, 2),
                    "incident_cost_b": round(incident_cost_b, 2),
                    "saving_per_incident": round(saving_per_incident, 2),
                    "break_even_incidents_per_year": round(be.incidents_per_year_to_break_even, 3),
                    "break_even_incidents_per_quarter": round(be.incidents_per_quarter_to_break_even, 3),
                },
                indent=2,
            )
        )
        return 0

    print("\n=== infra-a: single-AZ ===\n")
    print(cost_a.table())
    print("\n=== infra-b: multi-AZ + DR ===\n")
    print(cost_b.table())

    print("\n=== the delta ===\n")
    print(f"  infra-a            {cost_a.total:>10.2f} USD/month")
    print(f"  infra-b            {cost_b.total:>10.2f} USD/month")
    print(f"  difference         {delta:>10.2f} USD/month  ({delta * 12:,.0f}/year)")
    print(f"  of which HA        {cost_b.resilience_premium:>10.2f} USD/month in infra-b")

    label = "measured" if measured else "MODELLED"

    print("\n=== the break-even ===\n")
    if not measured:
        print("  !! RTOs below are MODELLED, not measured. Run scripts/run-experiment.sh")
        print("     against both stacks and pass --rto-a / --rto-b to get a real answer.\n")

    print(f"  assumed revenue    {args.revenue_per_hour:>10,.0f} USD/hour of outage")
    print(f"  {label:<8} RTO A     {rto_a:>10,.0f} s   -> {incident_cost_a:>12,.0f} USD/incident")
    print(f"  {label:<8} RTO B     {rto_b:>10,.0f} s   -> {incident_cost_b:>12,.0f} USD/incident")
    print(f"  saved per incident {saving_per_incident:>10,.0f} USD")
    print()
    print(f"  {be.summary()}")
    print()

    # The verdict, stated in the only terms a business actually decides in.
    per_quarter = be.incidents_per_quarter_to_break_even
    if per_quarter <= 1.0:
        print(
            f"  => infra-b pays for itself at {per_quarter:.2f} AZ incidents per quarter.\n"
            f"     AWS AZ impairments are not rare enough for that to be a safe bet against."
        )
    else:
        print(
            f"  => infra-b needs {per_quarter:.2f} AZ incidents per quarter to pay for itself.\n"
            f"     At that rate the spend is hard to justify on cost alone - it becomes a\n"
            f"     question of contractual SLA and reputation, not arithmetic."
        )

    # ------------------------------------------------------------------
    # The same question, asked the other way round.
    #
    # "It pays for itself at one incident a quarter" is the sentence everyone
    # wants to write. It is not a fact about the architecture - it is a fact about
    # how much an hour of downtime costs you, and it is true at exactly one value
    # of that. So rather than assert it, solve for it and let the reader decide
    # whether they believe the number.
    # ------------------------------------------------------------------
    required_revenue = revenue_for_target_break_even(
        delta, rto_a, rto_b, target_incidents_per_year=4.0,
        engineer_count=args.engineers, engineer_hourly_cost=args.engineer_hourly_cost,
    )

    print()
    print("=== inverted: what would make it break even at 1 incident/quarter? ===\n")
    print(f"  An hour of total outage would have to cost {required_revenue:,.0f} USD.")
    print(f"  You assumed {args.revenue_per_hour:,.0f}.")
    print()
    if args.revenue_per_hour > required_revenue:
        print(
            "  Your revenue assumption is HIGHER than that, so the spend is justified by\n"
            "  a rarer incident rate than one a quarter - the architecture is an easier\n"
            "  sell than the usual framing suggests."
        )
    else:
        print(
            "  Your revenue assumption is LOWER than that, so one incident a quarter is\n"
            "  not enough to justify the spend on cost grounds alone."
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
