"""Turn probe timelines into RTO and RPO.

owner: allaouiyounespro
portfolio: github.com/allaouiyounespro

Pure functions, no I/O, no clock, no network. Everything here is a
deterministic transformation of a list of samples into a number, which is what
makes it testable - and testing it is not optional, because these are the numbers
the entire project reports. An off-by-one in the recovery detector would quietly
change the headline result and nothing would look wrong.

Two definitions, stated up front, because a resilience report whose definitions
are implicit is a report you cannot argue with:

RTO  Recovery Time Objective, measured as: from the first failed request after
     the fault was injected, to the start of the first *sustained* run of
     successful requests.

     "Sustained" is doing real work in that sentence. During a recovery a service
     flaps - a pod passes readiness, takes traffic, its database connection
     turns out to be dead, it fails again. Taking the first lone success as
     "recovered" would report an RTO several minutes shorter than the truth. So
     recovery requires N consecutive successes, and the clock stops at the START
     of that run, not the end - because that first success is genuinely when the
     service came back; the following ones are merely the evidence that it stayed.

RPO  Recovery Point Objective, measured as: the time span of acknowledged writes
     that the database no longer has after recovery.

     Not "how many rows are missing" - that is a count, not an objective. RPO is
     denominated in time: if the writes the database lost span 4 minutes and 12
     seconds, the RPO is 4m12s, because that is how far back the business would
     have to reconstruct from.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Sequence

# A run of this many consecutive successes counts as "recovered". At the probe's
# 1-second interval that is 5 seconds of unbroken health.
#
# The value is a tradeoff and it is worth being honest about which way it errs:
# too low and a flapping service reports a recovery it has not achieved (RTO too
# optimistic); too high and a genuinely recovered service is not credited until
# later (RTO too pessimistic, by at most N seconds). Erring pessimistic is the
# right call - a resilience report that overstates recovery is worse than useless.
DEFAULT_STABILITY_RUN = 5


@dataclass(frozen=True)
class Sample:
    """One probe observation."""

    ts: float
    ok: bool
    status: int | None = None
    zone: str | None = None
    latency_ms: float | None = None
    error: str | None = None

    @staticmethod
    def from_json(raw: dict) -> "Sample":
        return Sample(
            ts=float(raw["ts"]),
            ok=bool(raw["ok"]),
            status=raw.get("status"),
            zone=raw.get("zone"),
            latency_ms=raw.get("latency_ms"),
            error=raw.get("error"),
        )


@dataclass(frozen=True)
class Ack:
    """One write the client believed was durable."""

    seq: int
    ts: float
    committed: bool

    @staticmethod
    def from_json(raw: dict) -> "Ack":
        return Ack(
            seq=int(raw["seq"]),
            ts=float(raw["ts"]),
            committed=bool(raw.get("committed", False)),
        )


@dataclass
class RTOResult:
    fault_start: float
    outage_start: float | None
    recovered_at: float | None
    rto_seconds: float | None
    detection_seconds: float | None
    total_samples: int
    failed_samples: int
    availability: float
    zones_seen_during_fault: list[str] = field(default_factory=list)
    survived: bool = False
    recovered: bool = True

    def summary(self) -> str:
        if self.survived:
            return "SURVIVED - no request ever failed; RTO = 0s"
        if not self.recovered:
            return (
                f"NOT RECOVERED - still failing at the end of the observation window "
                f"({self.failed_samples}/{self.total_samples} requests failed)"
            )
        return (
            f"RTO = {self.rto_seconds:.1f}s "
            f"(detected {self.detection_seconds:.1f}s after fault injection, "
            f"availability {self.availability:.2%})"
        )


@dataclass
class RPOResult:
    last_acked_seq: int | None
    last_acked_ts: float | None
    db_last_seq: int | None
    db_last_ts: float | None
    lost_writes: int
    rpo_seconds: float | None
    data_loss: bool

    def summary(self) -> str:
        if not self.data_loss:
            return "RPO = 0s - every acknowledged write survived"
        return (
            f"RPO = {self.rpo_seconds:.1f}s - {self.lost_writes} acknowledged "
            f"write(s) were lost (seq {self.db_last_seq} -> {self.last_acked_seq})"
        )


def load_samples(path: str | Path) -> list[Sample]:
    """Read an NDJSON probe timeline.

    Malformed lines are skipped rather than fatal. The probe writes one line per
    second for the length of an experiment and is itself running while an AZ is
    being destroyed; a truncated final line is a normal outcome, and losing an
    entire run's data to a ValueError on the last byte would be absurd.
    """
    samples: list[Sample] = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            samples.append(Sample.from_json(json.loads(line)))
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            continue
    return sorted(samples, key=lambda s: s.ts)


def load_acks(path: str | Path) -> list[Ack]:
    """Read an NDJSON write-acknowledgement timeline."""
    acks: list[Ack] = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            acks.append(Ack.from_json(json.loads(line)))
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            continue
    return sorted(acks, key=lambda a: a.seq)


def find_recovery(
    samples: Sequence[Sample],
    start_index: int,
    stability_run: int = DEFAULT_STABILITY_RUN,
) -> int | None:
    """Index of the first sample that begins a run of `stability_run` successes.

    Returns None if no such run exists - which is the honest answer when the
    service never came back inside the observation window, and is very much a
    possible outcome for infra-a, whose recovery depends on AWS restoring the AZ
    rather than on anything the architecture does.

    A trailing run shorter than stability_run does NOT count. If the probe stops
    two seconds after the service recovers, there is not enough evidence to call
    it recovered, and inventing the missing samples would be fabrication.
    """
    if stability_run < 1:
        raise ValueError("stability_run must be at least 1")

    run_start: int | None = None
    run_length = 0

    for i in range(start_index, len(samples)):
        if samples[i].ok:
            if run_start is None:
                run_start = i
            run_length += 1
            if run_length >= stability_run:
                return run_start
        else:
            run_start = None
            run_length = 0

    return None


def compute_rto(
    samples: Sequence[Sample],
    fault_start: float,
    stability_run: int = DEFAULT_STABILITY_RUN,
) -> RTOResult:
    """Measure recovery time from an availability timeline.

    `fault_start` is the moment FIS actually began injecting the fault, taken
    from the experiment's own record rather than from when the script felt like
    starting - the difference is routinely 10-20 seconds of API latency, and
    charging that to the architecture would be dishonest.
    """
    if not samples:
        raise ValueError("no samples: the probe produced nothing to analyse")

    during = [s for s in samples if s.ts >= fault_start]
    if not during:
        raise ValueError(
            "every sample predates fault_start - the probe stopped before the "
            "experiment began, or the clocks disagree"
        )

    failed = [s for s in during if not s.ok]
    availability = 1.0 - (len(failed) / len(during))
    zones = sorted({s.zone for s in during if s.ok and s.zone})

    # Nothing ever failed. This is the result infra-b is supposed to produce, and
    # it deserves to be reported as a distinct outcome rather than as "RTO = 0",
    # which reads like a measurement failure.
    if not failed:
        return RTOResult(
            fault_start=fault_start,
            outage_start=None,
            recovered_at=None,
            rto_seconds=0.0,
            detection_seconds=None,
            total_samples=len(during),
            failed_samples=0,
            availability=availability,
            zones_seen_during_fault=zones,
            survived=True,
            recovered=True,
        )

    outage_start = failed[0].ts
    first_failure_index = during.index(failed[0])

    recovery_index = find_recovery(during, first_failure_index, stability_run)

    if recovery_index is None:
        return RTOResult(
            fault_start=fault_start,
            outage_start=outage_start,
            recovered_at=None,
            rto_seconds=None,
            detection_seconds=outage_start - fault_start,
            total_samples=len(during),
            failed_samples=len(failed),
            availability=availability,
            zones_seen_during_fault=zones,
            survived=False,
            recovered=False,
        )

    recovered_at = during[recovery_index].ts

    return RTOResult(
        fault_start=fault_start,
        outage_start=outage_start,
        recovered_at=recovered_at,
        rto_seconds=recovered_at - outage_start,
        detection_seconds=outage_start - fault_start,
        total_samples=len(during),
        failed_samples=len(failed),
        availability=availability,
        zones_seen_during_fault=zones,
        survived=False,
        recovered=True,
    )


def compute_rpo(acks: Iterable[Ack], db_last_seq: int | None) -> RPOResult:
    """Measure data loss by comparing what the client was promised to what survived.

    `db_last_seq` is read from GET /last after the system has recovered.

    Only committed acks count. A write that returned 503 was never promised to
    anyone, so its absence from the database is not data loss - it is the system
    correctly refusing to lie. Counting those would inflate the RPO with writes
    that the client already knows it has to retry.
    """
    committed = sorted((a for a in acks if a.committed), key=lambda a: a.seq)

    if not committed:
        return RPOResult(
            last_acked_seq=None,
            last_acked_ts=None,
            db_last_seq=db_last_seq,
            db_last_ts=None,
            lost_writes=0,
            rpo_seconds=None,
            data_loss=False,
        )

    last_ack = committed[-1]

    # The database has everything the client was promised, or more. RPO is zero.
    #
    # "or more" is a real case, not a defensive branch: a write can commit and
    # then have its acknowledgement lost on the way back to a client whose
    # connection died with the AZ. The data is there; the client just never heard.
    # That is not data loss, and reporting a negative RPO would be nonsense.
    if db_last_seq is not None and db_last_seq >= last_ack.seq:
        return RPOResult(
            last_acked_seq=last_ack.seq,
            last_acked_ts=last_ack.ts,
            db_last_seq=db_last_seq,
            db_last_ts=None,
            lost_writes=0,
            rpo_seconds=0.0,
            data_loss=False,
        )

    # The database lost everything, or was never reachable to be read.
    if db_last_seq is None:
        return RPOResult(
            last_acked_seq=last_ack.seq,
            last_acked_ts=last_ack.ts,
            db_last_seq=None,
            db_last_ts=None,
            lost_writes=len(committed),
            rpo_seconds=last_ack.ts - committed[0].ts,
            data_loss=True,
        )

    lost = [a for a in committed if a.seq > db_last_seq]

    # Timestamp of the highest surviving write, taken from the client's own log.
    # Using the database's own written_at column instead would be circular: it is
    # the database's account of a period during which the database is exactly what
    # is under suspicion.
    surviving = [a for a in committed if a.seq <= db_last_seq]
    db_last_ts = surviving[-1].ts if surviving else committed[0].ts

    return RPOResult(
        last_acked_seq=last_ack.seq,
        last_acked_ts=last_ack.ts,
        db_last_seq=db_last_seq,
        db_last_ts=db_last_ts,
        lost_writes=len(lost),
        rpo_seconds=last_ack.ts - db_last_ts,
        data_loss=bool(lost),
    )
