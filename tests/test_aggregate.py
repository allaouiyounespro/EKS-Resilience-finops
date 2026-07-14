"""Tests for the multi-run aggregator.

owner: allaouiyounespro
portfolio: github.com/allaouiyounespro

This module decides the numbers that end up in docs/results.md and, from there,
in the break-even. Every test below is a specific way it could produce a
plausible, publishable, wrong figure.

The nastiest one is `test_a_never_recovered_run_is_not_silently_dropped`: it
would be trivially easy to filter out the run with `rto: null`, take the median
of the rest, and publish "infra-a recovers in 22 minutes" from a campaign in
which one run never recovered at all. It would look completely normal.
"""

from __future__ import annotations

import unittest

from chaos.aggregate import aggregate, markdown_table


def run(
    stack: str = "infra-a",
    rto: float | None = 100.0,
    recovered: bool = True,
    survived: bool = False,
    availability: float = 0.9,
    rpo: float | None = None,
    data_loss: bool = False,
    lost_writes: int = 0,
) -> dict:
    return {
        "stack": stack,
        "rto": {
            "seconds": rto,
            "recovered": recovered,
            "survived": survived,
            "availability": availability,
        },
        "rpo": {
            "seconds": rpo,
            "data_loss": data_loss,
            "lost_writes": lost_writes,
        },
    }


class TestMedian(unittest.TestCase):
    def test_median_not_mean(self):
        # 60, 90, 300. The mean is 150 - a value no run ever produced, dragged
        # up by one slow failover. The median is 90, which the system actually
        # did.
        agg = aggregate([run(rto=60), run(rto=90), run(rto=300)], "infra-a")

        self.assertEqual(agg.rto_median, 90.0)
        self.assertNotEqual(agg.rto_median, 150.0)

    def test_spread_is_reported(self):
        # The spread is what tells a reader whether the median means anything.
        # A median of 90s with a spread of 240s is a very different claim from a
        # median of 90s with a spread of 5s, and only one of them belongs in a
        # portfolio without a caveat.
        agg = aggregate([run(rto=60), run(rto=90), run(rto=300)], "infra-a")

        self.assertEqual(agg.rto_min, 60.0)
        self.assertEqual(agg.rto_max, 300.0)
        self.assertEqual(agg.rto_spread, 240.0)

    def test_all_runs_survived(self):
        # infra-b's target outcome. Reported as its own state, not as "RTO = 0",
        # which reads like the instrument failed.
        agg = aggregate([run(rto=0, survived=True, availability=1.0) for _ in range(3)], "infra-b")

        self.assertEqual(agg.runs_survived, 3)
        self.assertEqual(agg.rto_median, 0.0)
        self.assertIn("every run survived", agg.summary())


class TestNeverRecovered(unittest.TestCase):
    def test_a_never_recovered_run_is_not_silently_dropped(self):
        # THE test in this file.
        #
        # Two runs recovered in ~20 min; one never came back. Publishing a median
        # of the two survivors as the headline, with no mention of the third,
        # would be the single most dishonest thing this code could do - and it is
        # exactly what a naive `[r for r in rtos if r is not None]` produces.
        agg = aggregate(
            [run(rto=1200), run(rto=1300), run(rto=None, recovered=False)],
            "infra-a",
        )

        self.assertEqual(agg.runs_never_recovered, 1)
        self.assertEqual(agg.runs_recovered, 2)
        self.assertEqual(agg.rto_median, 1250.0)

        # The median is reported, but never without the warning attached.
        self.assertIn("never recovered", agg.summary())
        self.assertIn("the true figure is worse", agg.summary())

    def test_a_majority_of_non_recovery_refuses_to_report_a_median(self):
        # Two of three runs never came back. A median of the single survivor is
        # not a description of the system; it is a description of its luckiest
        # day. The aggregate declines rather than flattering.
        agg = aggregate(
            [run(rto=1200), run(rto=None, recovered=False), run(rto=None, recovered=False)],
            "infra-a",
        )

        self.assertIsNone(agg.rto_median)
        self.assertIn("NOT MEASURABLE", agg.summary())
        self.assertIn("2/3 runs never recovered", agg.summary())

    def test_no_run_ever_recovered(self):
        agg = aggregate([run(rto=None, recovered=False) for _ in range(3)], "infra-a")

        self.assertIsNone(agg.rto_median)
        self.assertEqual(agg.runs_never_recovered, 3)
        self.assertIn("NOT MEASURABLE", agg.summary())


class TestRPO(unittest.TestCase):
    def test_no_data_loss_anywhere(self):
        agg = aggregate([run(rpo=0.0, data_loss=False) for _ in range(3)], "infra-b")

        self.assertEqual(agg.runs_with_data_loss, 0)
        self.assertIn("no acknowledged write was ever lost", agg.summary())

    def test_worst_case_is_reported_alongside_the_median(self):
        # RPO is a promise about the worst case, not the typical case. A median
        # of 120s that hides a run which lost 300s of commits is a promise the
        # system does not keep.
        agg = aggregate(
            [
                run(rpo=100, data_loss=True, lost_writes=100),
                run(rpo=120, data_loss=True, lost_writes=120),
                run(rpo=300, data_loss=True, lost_writes=300),
            ],
            "infra-a",
        )

        self.assertEqual(agg.rpo_median, 120.0)
        self.assertEqual(agg.rpo_max, 300.0)
        self.assertEqual(agg.lost_writes_max, 300)
        self.assertIn("worst 300s", agg.summary())

    def test_a_single_lossy_run_among_clean_ones_still_counts(self):
        # Multi-AZ claims RPO = 0. One run out of three losing data falsifies
        # that claim, and must not be averaged into invisibility.
        agg = aggregate(
            [run(rpo=0, data_loss=False), run(rpo=0, data_loss=False), run(rpo=45, data_loss=True, lost_writes=45)],
            "infra-b",
        )

        self.assertEqual(agg.runs_with_data_loss, 1)
        self.assertEqual(agg.rpo_max, 45.0)
        self.assertIn("data loss in 1/3 run(s)", agg.summary())


class TestMarkdown(unittest.TestCase):
    def test_table_renders_a_never_recovered_median(self):
        agg = aggregate([run(rto=None, recovered=False) for _ in range(3)], "infra-a")
        table = markdown_table(agg)

        self.assertIn("**never recovered**", table)
        self.assertIn("| Runs that never recovered | 3 / 3 |", table)

    def test_long_durations_get_a_minutes_hint(self):
        # "1250 s" means nothing to a reader; "(20.8 min)" does.
        agg = aggregate([run(rto=1250)], "infra-a")
        self.assertIn("min)", markdown_table(agg))

    def test_short_durations_stay_in_seconds(self):
        agg = aggregate([run(rto=85)], "infra-b")
        table = markdown_table(agg)
        self.assertIn("85 s", table)
        self.assertNotIn("min)", table)


class TestGuards(unittest.TestCase):
    def test_empty_input_raises(self):
        with self.assertRaises(ValueError):
            aggregate([], "infra-a")


if __name__ == "__main__":
    unittest.main(verbosity=2)
