"""Tests for the FinOps model.

owner: allaouiyounespro
portfolio: github.com/allaouiyounespro

The cost model produces a number that someone might take to a budget meeting. It
therefore has to be right, and "right" here means two things that are easy to
confuse:

  1. the arithmetic is correct (tested against hand-computed line items)
  2. the two architectures are counted the SAME way, so the delta means something

Point 2 is the one that kills real comparisons. If infra-b's price includes a
line that infra-a's model silently omits, the delta is an artefact of the model
rather than of the architecture - and it will look completely plausible.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from finops.cost_model import (
    break_even,
    compute_cost,
    downtime_cost,
    load_yaml,
    revenue_for_target_break_even,
)

PRICING = load_yaml(Path(__file__).parent.parent / "finops" / "pricing.yaml")
SHAPES = load_yaml(Path(__file__).parent.parent / "finops" / "shapes.yaml")

HOURS = PRICING["meta"]["hours_per_month"]


class TestPricingData(unittest.TestCase):
    def test_every_instance_type_used_by_a_shape_has_a_price(self):
        # The failure this prevents is a KeyError deep in a budget meeting.
        ec2 = PRICING["compute"]["ec2_hourly"]
        rds = PRICING["database"]["rds_hourly"]

        for name, shape in SHAPES.items():
            self.assertIn(shape["node_instance_type"], ec2, f"{name}: unpriced system node type")
            self.assertIn(shape["karpenter_instance_type"], ec2, f"{name}: unpriced Karpenter node type")
            self.assertIn(shape["db_instance_class"], rds, f"{name}: unpriced DB class")

    def test_multi_az_is_exactly_double(self):
        # Not "roughly" double. AWS runs a full standby and bills it as a second
        # instance. If this constant ever drifts, the entire RPO=0 line item is
        # mispriced.
        self.assertEqual(PRICING["database"]["multi_az_multiplier"], 2.0)


class TestComputeCost(unittest.TestCase):
    def setUp(self):
        self.a = compute_cost(SHAPES["infra-a"], PRICING, "infra-a")
        self.b = compute_cost(SHAPES["infra-b"], PRICING, "infra-b")

    def test_eks_control_plane_is_identical_in_both(self):
        # The single largest line item that the resilience decision cannot
        # influence. If these ever differ, the comparison is broken.
        a_eks = next(i for i in self.a.items if i.name == "EKS control plane")
        b_eks = next(i for i in self.b.items if i.name == "EKS control plane")

        self.assertEqual(a_eks.monthly, b_eks.monthly)
        self.assertAlmostEqual(a_eks.monthly, 0.10 * HOURS, places=2)

    def test_infra_a_has_no_resilience_premium(self):
        # By definition: infra-a buys no high availability, so nothing in its
        # bill may be flagged as resilience-driven. A non-zero value here would
        # mean the flag is being applied by accident and the "of which HA" figure
        # is fiction.
        self.assertEqual(self.a.resilience_premium, 0.0)

    def test_infra_b_costs_more(self):
        self.assertGreater(self.b.total, self.a.total)

    def test_the_delta_is_entirely_explained_by_flagged_line_items(self):
        # THE test in this file.
        #
        # Every dollar of difference between the two architectures must trace to a
        # line item explicitly marked resilience_driven. If the delta exceeds the
        # flagged premium, some cost is creeping in that nobody decided to spend -
        # a bigger instance, an extra volume, a modelling slip - and the headline
        # "you pay X for resilience" claim is false.
        #
        # The two are not exactly equal: infra-b also has more EBS (more nodes)
        # and more CloudWatch logs, which are consequences of the HA decision
        # rather than the decision itself. So the flagged premium should account
        # for the large majority, and the unexplained remainder must be small.
        delta = self.b.total - self.a.total
        premium = self.b.resilience_premium
        unexplained = delta - premium

        self.assertGreater(premium, 0)
        self.assertLess(
            abs(unexplained),
            0.10 * delta,
            f"{unexplained:.2f} USD/month of the {delta:.2f} delta is not attributed "
            f"to any resilience line item - find out what it is before quoting the delta",
        )

    def test_multi_az_standby_appears_only_in_infra_b(self):
        a_names = {i.name for i in self.a.items}
        b_names = {i.name for i in self.b.items}

        self.assertNotIn("RDS Multi-AZ standby", a_names)
        self.assertIn("RDS Multi-AZ standby", b_names)

    def test_standby_costs_the_same_as_the_primary(self):
        # RPO=0 costs exactly one extra database. If this assertion fails, either
        # the multiplier or the storage handling has drifted.
        primary = next(i for i in self.b.items if i.name == "RDS instance").monthly
        storage = next(i for i in self.b.items if i.name == "RDS storage").monthly
        standby = next(i for i in self.b.items if i.name == "RDS Multi-AZ standby").monthly

        self.assertAlmostEqual(standby, primary + storage, places=2)

    def test_infra_a_has_exactly_one_nat_gateway(self):
        names = [i.name for i in self.a.items]
        self.assertIn("NAT Gateway", names)
        self.assertNotIn("NAT Gateway (HA)", names)

    def test_infra_b_pays_for_two_extra_nat_gateways(self):
        ha_nat = next(i for i in self.b.items if i.name == "NAT Gateway (HA)")
        expected = PRICING["network"]["nat_gateway_hourly"] * HOURS * 2
        self.assertAlmostEqual(ha_nat.monthly, expected, places=2)

    def test_single_az_has_no_cross_az_transfer(self):
        # Both a cost fact and a resilience fact, and they are the same fact:
        # nothing crosses an AZ boundary because there is only one AZ.
        self.assertNotIn("Cross-AZ data transfer", {i.name for i in self.a.items})

    def test_total_is_the_sum_of_its_parts(self):
        self.assertAlmostEqual(self.a.total, sum(i.monthly for i in self.a.items), places=6)


class TestDowntimeCost(unittest.TestCase):
    def test_one_hour_of_outage(self):
        # 1h at 5000/hr revenue + 3 engineers at 120/hr = 5000 + 360.
        cost = downtime_cost(3600, revenue_per_hour=5000, engineer_count=3, engineer_hourly_cost=120)
        self.assertAlmostEqual(cost, 5360.0)

    def test_scales_linearly_with_duration(self):
        one = downtime_cost(3600, revenue_per_hour=1000)
        two = downtime_cost(7200, revenue_per_hour=1000)
        self.assertAlmostEqual(two, 2 * one)

    def test_zero_rto_costs_nothing(self):
        # infra-b's ideal outcome. A survived AZ failure costs zero, and the
        # model must not manufacture a floor cost out of nowhere.
        self.assertEqual(downtime_cost(0, revenue_per_hour=5000), 0.0)

    def test_engineering_time_is_counted_even_with_no_revenue(self):
        # An internal platform with no direct revenue still costs money when it
        # breaks: people stop doing their jobs. A model that ignores this
        # concludes that internal systems should never be made resilient.
        cost = downtime_cost(3600, revenue_per_hour=0, engineer_count=4, engineer_hourly_cost=100)
        self.assertAlmostEqual(cost, 400.0)

    def test_reputational_multiplier_is_off_by_default(self):
        # It must be opt-in. It is the term that lets anyone justify any spend by
        # asserting a big enough number, and a default of 1.0 forces whoever uses
        # it to own it.
        plain = downtime_cost(3600, revenue_per_hour=1000)
        explicit = downtime_cost(3600, revenue_per_hour=1000, reputational_multiplier=1.0)
        self.assertEqual(plain, explicit)

    def test_negative_rto_is_rejected(self):
        with self.assertRaises(ValueError):
            downtime_cost(-1, revenue_per_hour=1000)


class TestBreakEven(unittest.TestCase):
    def test_basic_arithmetic(self):
        # 100/month = 1200/year. At 600 saved per incident, two incidents a year.
        be = break_even(monthly_delta=100.0, cost_per_incident=600.0)

        self.assertAlmostEqual(be.annual_delta, 1200.0)
        self.assertAlmostEqual(be.incidents_per_year_to_break_even, 2.0)
        self.assertAlmostEqual(be.incidents_per_quarter_to_break_even, 0.5)

    def test_a_costlier_incident_lowers_the_bar(self):
        cheap = break_even(100.0, 600.0)
        pricey = break_even(100.0, 6000.0)
        self.assertLess(
            pricey.incidents_per_year_to_break_even,
            cheap.incidents_per_year_to_break_even,
        )

    def test_a_free_outage_justifies_no_spend(self):
        with self.assertRaises(ValueError):
            break_even(100.0, 0.0)


class TestInvertedBreakEven(unittest.TestCase):
    """The solver that turns the claim into an assumption you have to own."""

    def test_it_is_the_exact_inverse_of_break_even(self):
        # Round-trip: solve for the revenue that yields 4 incidents/year, feed it
        # back through the forward model, and the answer must be 4 incidents/year.
        #
        # This is the test that makes the inverted figure trustworthy. Without it,
        # a sign error in the algebra would produce a confident, wrong number that
        # nobody could check by eye.
        monthly_delta = 193.55
        rto_a, rto_b = 1920.0, 94.0

        revenue = revenue_for_target_break_even(
            monthly_delta, rto_a, rto_b, target_incidents_per_year=4.0,
            engineer_count=3, engineer_hourly_cost=120.0,
        )

        saving = downtime_cost(rto_a, revenue, 3, 120.0) - downtime_cost(rto_b, revenue, 3, 120.0)
        be = break_even(monthly_delta, saving)

        self.assertAlmostEqual(be.incidents_per_year_to_break_even, 4.0, places=6)

    def test_round_trips_at_several_target_rates(self):
        for target in (0.5, 1.0, 2.0, 4.0, 12.0):
            with self.subTest(target=target):
                revenue = revenue_for_target_break_even(200.0, 1800.0, 90.0, target)
                saving = downtime_cost(1800.0, revenue) - downtime_cost(90.0, revenue)
                be = break_even(200.0, saving)
                self.assertAlmostEqual(be.incidents_per_year_to_break_even, target, places=6)

    def test_no_rto_improvement_means_no_justification_at_any_revenue(self):
        # If the expensive architecture does not actually recover faster, no
        # revenue figure on earth justifies it - and the model says so instead of
        # dividing by something near zero and emitting a huge, meaningless number.
        with self.assertRaises(ValueError):
            revenue_for_target_break_even(200.0, rto_a_seconds=100.0, rto_b_seconds=100.0,
                                          target_incidents_per_year=4.0)

        with self.assertRaises(ValueError):
            revenue_for_target_break_even(200.0, rto_a_seconds=50.0, rto_b_seconds=100.0,
                                          target_incidents_per_year=4.0)

    def test_zero_incidents_is_rejected(self):
        with self.assertRaises(ValueError):
            revenue_for_target_break_even(200.0, 1800.0, 90.0, target_incidents_per_year=0.0)


class TestRealShapes(unittest.TestCase):
    """Guardrails on the actual numbers this project reports."""

    def setUp(self):
        self.a = compute_cost(SHAPES["infra-a"], PRICING, "infra-a")
        self.b = compute_cost(SHAPES["infra-b"], PRICING, "infra-b")

    def test_the_delta_is_in_the_documented_range(self):
        # docs/finops-analysis.md quotes ~194 USD/month. If a price or a shape
        # changes, this fails and the documentation gets updated - rather than
        # the README quietly becoming a lie.
        delta = self.b.total - self.a.total
        self.assertGreater(delta, 150.0)
        self.assertLess(delta, 250.0)

    def test_infra_b_is_not_double_infra_a(self):
        # A useful sanity check on the framing. The common intuition is "HA costs
        # twice as much"; here it is +79%, because the largest line item (the EKS
        # control plane) is fixed and buys nothing either way.
        self.assertLess(self.b.total, 2.0 * self.a.total)


if __name__ == "__main__":
    unittest.main(verbosity=2)
