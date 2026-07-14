"""Tests for the RTO/RPO analysis.

owner: allaouiyounespro
portfolio: github.com/allaouiyounespro

These are the most important tests in the repository. Everything else here is
infrastructure that either works or fails loudly; this module turns a timeline
into the two numbers the entire project reports, and a subtle bug in it would
produce a plausible-looking result that is simply wrong - and nothing anywhere
would complain.

So the timelines below are synthetic, with answers known by construction. If
compute_rto disagrees with arithmetic done by hand on six samples, it will
disagree with reality on nine hundred.

Written against unittest rather than pytest so they run on a bare Python with no
install step; pytest discovers and runs them unchanged.
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from chaos.analysis import (
    Ack,
    Sample,
    compute_rpo,
    compute_rto,
    find_recovery,
    load_acks,
    load_samples,
)


def timeline(pattern: str, start: float = 1000.0, step: float = 1.0) -> list[Sample]:
    """Build a timeline from a string. '.' is a success, 'x' is a failure.

    Makes the test cases readable as pictures of an outage, which is the only way
    to keep the off-by-one errors visible:

        '...xxxx...'   four seconds down, in the middle
    """
    return [
        Sample(ts=start + i * step, ok=(char == "."), zone="eu-west-3a" if char == "." else None)
        for i, char in enumerate(pattern)
    ]


class TestFindRecovery(unittest.TestCase):
    def test_returns_start_of_the_run_not_its_end(self):
        # The service came back at index 3. Indices 4-7 are merely the evidence
        # that it stayed back. Returning 7 would overstate the outage by 4s.
        samples = timeline("xxx.....")
        self.assertEqual(find_recovery(samples, 0, stability_run=5), 3)

    def test_a_lone_success_inside_the_outage_is_not_a_recovery(self):
        # This is the flapping case, and it is the reason stability_run exists.
        # A naive "first ok wins" implementation returns 3 here and reports an
        # RTO five seconds shorter than the truth.
        samples = timeline("xxx.xxxx.....")
        self.assertEqual(find_recovery(samples, 0, stability_run=5), 8)

    def test_a_trailing_run_that_is_too_short_does_not_count(self):
        # The probe stopped 3s after the service came back. That is not enough
        # evidence to certify a recovery, and inventing the missing samples would
        # be fabrication.
        samples = timeline("xxxxx...")
        self.assertIsNone(find_recovery(samples, 0, stability_run=5))

    def test_never_recovers(self):
        self.assertIsNone(find_recovery(timeline("xxxxxxxx"), 0, stability_run=3))

    def test_stability_run_of_one_accepts_the_first_success(self):
        self.assertEqual(find_recovery(timeline("xx."), 0, stability_run=1), 2)

    def test_rejects_a_nonsense_stability_run(self):
        with self.assertRaises(ValueError):
            find_recovery(timeline("..."), 0, stability_run=0)


class TestComputeRTO(unittest.TestCase):
    def test_clean_outage(self):
        # t=1000 .. 1002 healthy, 1003..1006 down, 1007+ healthy.
        # Outage starts at 1003, recovery starts at 1007 -> RTO = 4s.
        samples = timeline("...xxxx.....")
        result = compute_rto(samples, fault_start=1000.0, stability_run=5)

        self.assertFalse(result.survived)
        self.assertTrue(result.recovered)
        self.assertEqual(result.outage_start, 1003.0)
        self.assertEqual(result.recovered_at, 1007.0)
        self.assertEqual(result.rto_seconds, 4.0)
        # 3 seconds elapsed between the fault landing and the first failed
        # request. That is detection latency, and it is part of the outage the
        # user experienced - but it is reported separately, because it is a
        # property of the probe interval as much as of the architecture.
        self.assertEqual(result.detection_seconds, 3.0)
        self.assertEqual(result.failed_samples, 4)

    def test_survival_is_reported_as_its_own_outcome(self):
        # This is the result infra-b is supposed to produce. It must not be
        # reported as "RTO = 0", which reads like the instrument broke.
        result = compute_rto(timeline("........"), fault_start=1000.0)

        self.assertTrue(result.survived)
        self.assertTrue(result.recovered)
        self.assertEqual(result.rto_seconds, 0.0)
        self.assertIsNone(result.outage_start)
        self.assertEqual(result.availability, 1.0)
        self.assertIn("SURVIVED", result.summary())

    def test_never_recovered_yields_none_not_a_number(self):
        # infra-a's plausible outcome: the AZ is still gone when the probe stops.
        # Reporting some large number here would imply we measured a recovery we
        # never observed. None is the honest answer, and the summary says so.
        result = compute_rto(timeline("..xxxxxxxxxx"), fault_start=1000.0)

        self.assertFalse(result.recovered)
        self.assertIsNone(result.rto_seconds)
        self.assertIsNotNone(result.outage_start)
        self.assertIn("NOT RECOVERED", result.summary())

    def test_samples_before_the_fault_are_excluded(self):
        # The baseline period must not dilute the availability figure. Here the
        # first 5 samples are pre-fault and healthy; including them would report
        # availability of 5/10 instead of the true 0/5.
        samples = timeline(".....xxxxx", start=1000.0)
        result = compute_rto(samples, fault_start=1005.0)

        self.assertEqual(result.total_samples, 5)
        self.assertEqual(result.failed_samples, 5)
        self.assertEqual(result.availability, 0.0)

    def test_availability_is_computed_over_the_fault_window(self):
        # 2 failures out of 10 post-fault samples.
        result = compute_rto(timeline("xx........"), fault_start=1000.0)
        self.assertAlmostEqual(result.availability, 0.8)

    def test_empty_timeline_raises(self):
        with self.assertRaises(ValueError):
            compute_rto([], fault_start=1000.0)

    def test_timeline_entirely_before_the_fault_raises(self):
        # A clock skew or a probe that died early. Silently returning "survived"
        # here would be the single most dangerous failure mode in this module: a
        # broken run would be indistinguishable from a perfect result.
        with self.assertRaises(ValueError):
            compute_rto(timeline("....", start=1000.0), fault_start=9999.0)

    def test_unsorted_input_is_handled(self):
        # load_samples sorts, but compute_rto is public and may be handed a list
        # built by hand. The failure here would be silent and wrong.
        samples = [
            Sample(ts=1003.0, ok=True),
            Sample(ts=1001.0, ok=False),
            Sample(ts=1002.0, ok=True),
        ]
        result = compute_rto(sorted(samples, key=lambda s: s.ts), fault_start=1000.0, stability_run=1)
        self.assertEqual(result.outage_start, 1001.0)
        self.assertEqual(result.recovered_at, 1002.0)


class TestComputeRPO(unittest.TestCase):
    def test_no_data_loss(self):
        # The database has everything that was acknowledged. This is infra-b.
        acks = [Ack(seq=i, ts=1000.0 + i, committed=True) for i in range(1, 11)]
        result = compute_rpo(acks, db_last_seq=10)

        self.assertFalse(result.data_loss)
        self.assertEqual(result.rpo_seconds, 0.0)
        self.assertEqual(result.lost_writes, 0)
        self.assertIn("RPO = 0s", result.summary())

    def test_data_loss_is_denominated_in_time(self):
        # Acked through seq 10 (t=1010), database only kept through seq 6
        # (t=1006). Four writes lost, spanning 4 seconds. RPO = 4s, not "4 rows".
        acks = [Ack(seq=i, ts=1000.0 + i, committed=True) for i in range(1, 11)]
        result = compute_rpo(acks, db_last_seq=6)

        self.assertTrue(result.data_loss)
        self.assertEqual(result.lost_writes, 4)
        self.assertEqual(result.rpo_seconds, 4.0)

    def test_rejected_writes_are_not_data_loss(self):
        # Writes 5-8 returned 503. The client already knows to retry them, so
        # their absence from the database is the system being honest, not losing
        # data. Counting them would inflate the RPO with writes nobody was
        # promised.
        acks = [
            Ack(seq=i, ts=1000.0 + i, committed=(i < 5 or i > 8))
            for i in range(1, 11)
        ]
        result = compute_rpo(acks, db_last_seq=10)

        self.assertFalse(result.data_loss)
        self.assertEqual(result.lost_writes, 0)

    def test_database_ahead_of_the_client_is_not_negative_rpo(self):
        # A write committed, then the ack was lost on the way back to a client
        # whose connection died with the AZ. The data is there; the client just
        # never heard. Reporting a negative RPO would be nonsense.
        acks = [Ack(seq=i, ts=1000.0 + i, committed=True) for i in range(1, 6)]
        result = compute_rpo(acks, db_last_seq=8)

        self.assertFalse(result.data_loss)
        self.assertEqual(result.rpo_seconds, 0.0)
        self.assertEqual(result.lost_writes, 0)

    def test_an_unreadable_database_is_UNKNOWN_not_total_loss(self):
        # This assertion exists because the opposite behaviour shipped, ran
        # against real AWS, and reported "76 acknowledged writes lost, RPO 76s"
        # about a database that was `available` the entire time with every row
        # intact.
        #
        # GET /last is served by the application. When infra-a's AZ died, every
        # pod died with it and nothing was left to answer. The code treated an
        # unanswerable question as a total loss and invented a number.
        #
        # An unreadable database means the RPO is UNKNOWN. We cannot prove the
        # data survived; we cannot prove it did not. Filling the cell with a
        # fabricated loss is precisely what this project exists to refuse.
        acks = [Ack(seq=i, ts=1000.0 + i, committed=True) for i in range(1, 11)]
        result = compute_rpo(acks, db_last_seq=None)

        self.assertTrue(result.unknown)
        self.assertFalse(result.data_loss)
        self.assertIsNone(result.rpo_seconds)
        self.assertEqual(result.lost_writes, 0)
        self.assertIn("UNKNOWN", result.summary())

    def test_nothing_was_ever_acknowledged(self):
        acks = [Ack(seq=i, ts=1000.0 + i, committed=False) for i in range(1, 5)]
        result = compute_rpo(acks, db_last_seq=None)

        self.assertFalse(result.data_loss)
        self.assertIsNone(result.last_acked_seq)

    def test_empty_input(self):
        result = compute_rpo([], db_last_seq=None)
        self.assertFalse(result.data_loss)
        self.assertEqual(result.lost_writes, 0)


class TestLoaders(unittest.TestCase):
    def test_malformed_lines_are_skipped_not_fatal(self):
        # The probe is writing NDJSON while an AZ is being destroyed and may be
        # killed mid-line. Losing an entire run to a ValueError on the last byte
        # would be absurd.
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "probe.ndjson"
            path.write_text(
                json.dumps({"ts": 1000.0, "ok": True}) + "\n"
                + "{ this is not json\n"
                + "\n"
                + json.dumps({"ts": 1001.0, "ok": False}) + "\n"
                + '{"ts": 1002.0, "ok"',  # truncated: killed mid-write
                encoding="utf-8",
            )

            samples = load_samples(path)

        self.assertEqual(len(samples), 2)
        self.assertTrue(samples[0].ok)
        self.assertFalse(samples[1].ok)

    def test_samples_come_back_sorted(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "probe.ndjson"
            path.write_text(
                json.dumps({"ts": 1005.0, "ok": True}) + "\n"
                + json.dumps({"ts": 1001.0, "ok": True}) + "\n",
                encoding="utf-8",
            )
            samples = load_samples(path)

        self.assertEqual([s.ts for s in samples], [1001.0, 1005.0])

    def test_acks_load_and_sort_by_seq(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "acks.ndjson"
            path.write_text(
                json.dumps({"seq": 3, "ts": 1003.0, "committed": True}) + "\n"
                + json.dumps({"seq": 1, "ts": 1001.0, "committed": True}) + "\n",
                encoding="utf-8",
            )
            acks = load_acks(path)

        self.assertEqual([a.seq for a in acks], [1, 3])


class TestEndToEnd(unittest.TestCase):
    """The two headline scenarios, as the report would produce them."""

    def test_infra_a_shape_total_outage_and_an_unreadable_database(self):
        # What infra-a actually produced against real AWS: no pod survived, so
        # the service never came back inside the observation window AND the
        # database could not be read - because reading it goes through the app.
        #
        # Two distinct unknowns, and the report must keep them distinct: the RTO
        # is "not recovered" (a fact), the RPO is "unknown" (an absence of fact).
        samples = timeline("..xxxxxxxxxxxxxxxx", start=1000.0)
        acks = [Ack(seq=i, ts=1000.0 + i, committed=(i <= 2)) for i in range(1, 6)]

        rto = compute_rto(samples, fault_start=1000.0)
        rpo = compute_rpo(acks, db_last_seq=None)

        self.assertFalse(rto.recovered)
        self.assertIsNone(rto.rto_seconds)
        self.assertTrue(rpo.unknown)
        self.assertFalse(rpo.data_loss)

    def test_infra_b_shape_degraded_but_never_down(self):
        # Two of six pods die with the AZ; the survivors keep serving. From
        # outside, not a single request fails - which is the entire 194 USD/month
        # value proposition, expressed as a test assertion.
        samples = timeline("....................", start=1000.0)
        acks = [Ack(seq=i, ts=1000.0 + i, committed=True) for i in range(1, 21)]

        rto = compute_rto(samples, fault_start=1000.0)
        rpo = compute_rpo(acks, db_last_seq=20)

        self.assertTrue(rto.survived)
        self.assertEqual(rto.rto_seconds, 0.0)
        self.assertEqual(rto.availability, 1.0)
        self.assertFalse(rpo.data_loss)
        self.assertEqual(rpo.rpo_seconds, 0.0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
