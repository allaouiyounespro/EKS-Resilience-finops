"""Chaos experiment tooling for eks-resilience-finops.

owner: allaouiyounespro
portfolio: github.com/allaouiyounespro

    probe     an availability probe that runs OUTSIDE the cluster
    writer    a durability probe that records what it believed was committed
    analysis  pure functions that turn those two timelines into RTO and RPO

The split between the probes and the analysis is deliberate: the probes do I/O
and cannot be unit-tested without a live AWS account, while the analysis is pure
and is where every arithmetic mistake that would misreport an RTO actually lives.
So the analysis is a separate module with no I/O in it at all, and tests/ hits it
hard with synthetic timelines whose correct answers are known by construction.
"""

__version__ = "0.1.0"
