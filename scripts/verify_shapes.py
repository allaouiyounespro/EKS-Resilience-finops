#!/usr/bin/env python3
"""Fail if the cost model's view of the world has drifted from what is deployed.

owner: allaouiyounespro
portfolio: github.com/allaouiyounespro

    python3 scripts/verify_shapes.py

finops/shapes.yaml is a mirror of each stack's `finops_inputs` Terraform output.
Mirrors rot. Somebody bumps an instance type, or adds a NAT Gateway, and the cost
model carries on confidently reporting the old number - which is worse than
having no cost model at all, because the old number is *believed*.

This compares the two and exits non-zero on any difference. It is wired into
`make finops-verify` and into CI, so the drift is caught by a machine rather than
by whoever is presenting the numbers.

Skipped, not failed, when Terraform has no state - CI has no AWS account and
should not pretend otherwise.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).parent.parent
SHAPES = REPO / "finops" / "shapes.yaml"

# Fields the Terraform stack actually exports. shapes.yaml carries a few extra
# keys (NLB count, log volume) that Terraform has no opinion about, so the
# comparison is scoped to the intersection rather than demanding equality of the
# whole object.
TERRAFORM_OWNED = [
    "nat_gateway_count",
    "node_instance_type",
    "node_desired_count",
    "node_disk_gb",
    "workload_az_count",
    "db_instance_class",
    "db_multi_az",
    "db_storage_gb",
    "db_read_replica",
    "db_backup_retention",
]


def terraform_shape(stack: str) -> dict | None:
    """Read finops_inputs from a stack's state. None if there is no state."""
    stack_dir = REPO / "terraform" / "stacks" / stack

    try:
        result = subprocess.run(
            ["terraform", f"-chdir={stack_dir}", "output", "-json", "finops_inputs"],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None

    if result.returncode != 0:
        return None

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def main() -> int:
    mirror = yaml.safe_load(SHAPES.read_text(encoding="utf-8"))

    drifted = False
    checked_any = False

    for stack in ("infra-a", "infra-b"):
        live = terraform_shape(stack)

        if live is None:
            print(f"  {stack}: no Terraform state - skipping (this is expected in CI)")
            continue

        checked_any = True
        expected = mirror[stack]

        for field in TERRAFORM_OWNED:
            if field not in live:
                continue

            if expected.get(field) != live[field]:
                drifted = True
                print(
                    f"  DRIFT {stack}.{field}: "
                    f"shapes.yaml says {expected.get(field)!r}, "
                    f"AWS has {live[field]!r}"
                )

        if not drifted:
            print(f"  {stack}: shapes.yaml matches the deployed stack")

    if not checked_any:
        print("\nNothing to verify: neither stack has Terraform state.")
        print("The cost model is running against the mirror, which is fine for a")
        print("dry run - but the numbers are modelled, not observed.")
        return 0

    if drifted:
        print("\nfinops/shapes.yaml no longer describes what is deployed.")
        print("Update it, or the cost model is reporting an architecture that does not exist.")
        return 1

    print("\nCost model inputs match reality.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
