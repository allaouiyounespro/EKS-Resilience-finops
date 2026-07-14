"""Every Terraform output a script reads must actually exist.

owner: allaouiyounespro

This file exists because `scripts/teardown.sh` read `terraform output -raw vpc_id`
from a stack that did not declare it. The command returns an empty string and
exits non-zero; the script, being best-effort about a cluster that may be broken,
carried on with VPC="" and swept nothing.

The security groups it was supposed to delete - the ones EKS, the VPC CNI and the
Load Balancer Controller each leave behind, which cross-reference each other and
block the VPC from ever being deleted - would have survived. So would the VPC.

Nothing would have errored. The teardown would have looked like it worked.

Both stacks must expose the same output names, too: every script is written once
and pointed at either stack, so an output that exists in one and not the other is
a script that works on infra-a and silently misbehaves on infra-b.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO = Path(__file__).parent.parent
STACKS = ["infra-a", "infra-b"]


def declared_outputs(stack: str) -> set[str]:
    text = (REPO / "terraform" / "stacks" / stack / "outputs.tf").read_text(encoding="utf-8")
    return set(re.findall(r'^output\s+"([a-z_]+)"', text, re.MULTILINE))


def outputs_used_by_scripts() -> set[str]:
    used: set[str] = set()

    for script in (REPO / "scripts").glob("*.sh"):
        text = script.read_text(encoding="utf-8")

        # terraform output -raw <name>
        used.update(re.findall(r"output\s+-raw\s+([a-z_]+)", text))

        # jq -r '.<name>.value' over `terraform output -json`
        used.update(re.findall(r"'\.([a-z_]+)\.value", text))

    return used


class TestScriptsAndOutputsAgree(unittest.TestCase):
    def test_every_output_a_script_reads_is_declared_by_both_stacks(self):
        used = outputs_used_by_scripts()
        self.assertGreater(len(used), 0, "no outputs found - the regexes are wrong, not the code")

        for stack in STACKS:
            declared = declared_outputs(stack)
            missing = used - declared

            with self.subTest(stack=stack):
                self.assertEqual(
                    missing, set(),
                    f"{stack} does not declare {sorted(missing)}, but a script in scripts/ reads it. "
                    f"terraform output returns empty and the script carries on doing nothing.",
                )

    def test_both_stacks_expose_the_same_outputs(self):
        # Every script is written once and pointed at either stack. An output that
        # exists in one and not the other is a script that works on infra-a and
        # quietly misbehaves on infra-b - which is the harder of the two to notice,
        # because by then you are two hours and one AZ failure into a campaign.
        a, b = declared_outputs("infra-a"), declared_outputs("infra-b")

        self.assertEqual(
            a, b,
            f"only in infra-a: {sorted(a - b)}; only in infra-b: {sorted(b - a)}",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
