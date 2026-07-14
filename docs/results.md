# Results

owner: allaouiyounespro · portfolio: github.com/allaouiyounespro

> **STATUS: NOT YET MEASURED.**
>
> This is a template. Every cell below is empty because the experiment has not
> been run against real AWS infrastructure yet. The numbers in `finops/` are
> *modelled predictions*, and this file exists to hold what actually happened
> once they are tested.
>
> Filling these cells with plausible-looking numbers would be the single easiest
> thing to do in this whole project, and it would make the entire repository
> worthless. A resilience portfolio is a claim that you measure things instead of
> assuming them; inventing the measurements inverts the claim.
>
> Run `make up STACK=infra-a && make experiment STACK=infra-a`, then the same for
> `infra-b`, then paste the contents of `results/<stack>/<run>/result.json` here.

---

## What was predicted

Before running anything, the architecture predicts the following. Recording the
prediction *first* is the point: it is what makes the run falsifiable, and it is
what stops the results from being quietly reinterpreted afterwards to match
whatever happened.

| | infra-a (single-AZ) | infra-b (multi-AZ + DR) |
|---|---|---|
| **Predicted RTO** | 20-40 min | 60-120 s |
| **Predicted RPO** | up to 5 min | 0 s |
| **Why** | No standby: recovery waits for AWS to restore the AZ. Karpenter cannot help — its NodePool permits one zone, and that zone is gone. | RDS fails over to its synchronous standby (60-120s, and this dominates); Karpenter launches replacement nodes in the surviving AZs in parallel. |
| **Cost** | $244.83/mo | $438.38/mo |

The RPO prediction is the sharpest one. infra-a's floor is set by how often RDS
ships transaction logs to S3 — roughly every 5 minutes — so a point-in-time
restore loses up to 5 minutes of *committed* transactions. infra-b acknowledges
no commit until it is durable in two AZs, so its RPO should be exactly zero.
Not "near zero". Zero. If the measurement shows otherwise, something in the
Multi-AZ story is not what AWS says it is, and that would be the most interesting
result this project could produce.

---

## What was measured

### infra-a — single-AZ

| metric | value |
|---|---|
| RTO | _pending_ |
| RPO | _pending_ |
| Availability during fault | _pending_ |
| Acknowledged writes lost | _pending_ |
| Zones serving during fault | _pending_ |
| Recovered within the observation window? | _pending_ |

### infra-b — multi-AZ + DR

| metric | value |
|---|---|
| RTO | _pending_ |
| RPO | _pending_ |
| Availability during fault | _pending_ |
| Acknowledged writes lost | _pending_ |
| Zones serving during fault | _pending_ |
| Recovered within the observation window? | _pending_ |

### The break-even, recomputed from the measurements

Once both RTOs are real, re-run the model with them instead of the predictions:

```bash
python3 -m finops.cost_model --rto-a <measured> --rto-b <measured> --revenue-per-hour <yours>
```

| | value |
|---|---|
| Monthly delta | $193.55 |
| Annual delta | $2,323 |
| Saving per avoided incident | _pending_ |
| **Break-even incident rate** | _pending_ |

---

## Evidence

Each run leaves an immutable trail. Nothing in the table above should be believed
without it:

| artefact | what it proves |
|---|---|
| `results/<stack>/<run>/probe.ndjson` | Second-by-second availability from **outside** the cluster. The authoritative RTO. |
| `results/<stack>/<run>/acks.ndjson` | Every write the client was *promised* was durable. The authoritative RPO. |
| `results/<stack>/<run>/result.json` | The computed numbers, re-derivable from the two files above. |
| FIS experiment log group | When each fault action actually started. The clock everything else is anchored to. |
| VPC Flow Logs | Independent proof that traffic really did stop crossing the AZ boundary. |

The probe runs outside the blast radius on purpose. Prometheus is *inside* the
cluster being destroyed — its scrapes fail during the fault, its WAL can gap, and
if it happened to be scheduled in the doomed AZ it stops existing altogether.
Asking a system to report on its own death produces a suspiciously flattering
obituary. Prometheus explains *why* the outage happened; the external probe
establishes *that* it did, and for how long.

---

## Known limitations of the method

Stated up front, because a résumé project that only lists its strengths is
advertising, not engineering.

1. **One run is an anecdote.** RDS failover time varies by tens of seconds run to
   run. A defensible RTO needs 5+ runs per architecture and a median, not a
   single number. The tooling supports this; the AWS bill is what limits it.

2. **FIS's AZ failure is a simulation, not the real thing.** It disrupts
   connectivity and stops instances. A genuine AZ event is messier: partial
   failures, degraded-but-not-dead hardware, control-plane slowness, and a
   thundering herd of *every other AWS customer* failing over at the same moment.
   The measured RTO is therefore a **lower bound**. Reality will be worse.

3. **The witness app is trivial.** It has no cache to warm, no leader election, no
   long-running connections to re-establish. A real application's RTO includes all
   of that, and it is frequently the dominant term. What is measured here is the
   *infrastructure's* recovery time, which is a floor under the application's.

4. **Cross-region failure is out of scope.** infra-b survives an AZ. It does not
   survive a region. The read replica is a manual promotion path, not a tested
   one, and calling it "DR" is generous — honest DR means measuring a
   cross-region failover too.
