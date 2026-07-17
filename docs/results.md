# Results

owner: allaouiyounespro · portfolio: github.com/allaouiyounespro

**infra-a was built on AWS and destroyed by AWS FIS. These are the measurements.**
infra-b has not been run yet — its cells are empty, and they will stay empty
until it is. Filling them with plausible numbers would be the easiest thing in
this repository and would make the whole thing worthless.

---

## infra-a — single-AZ

![The outage](outage-infra-a.svg)

| metric | value |
|---|---|
| **RTO** | **NOT RECOVERED** — still down at the end of the observation window |
| **RPO** | **UNKNOWN** — see below |
| Availability during the fault | **2.71%** |
| Failed requests | **502 / 516** |
| Zones serving during the fault | none |
| Karpenter nodes launched during the fault | **0** |
| Pods Pending during the fault | **6 / 6** |
| Human intervention required to recover | **yes** |

Run: `results/infra-a/20260714T183355Z/` · fault: AWS FIS, `eu-west-3a`, 15 minutes,
network fully isolated + all nodes stopped.

### What happened

The AZ was cut off and every node in it was stopped. That included the **system
nodes**, which is where the Karpenter controller runs — and infra-a, by
definition, has no second AZ to keep a spare controller in.

**Karpenter died with the workload.** With the controller gone, nothing was left
to provision replacement capacity. The six pods went Pending and stayed Pending.

Then the fault ended, and the service still did not come back.

The Auto Scaling Group had launched replacement instances *during* the network
outage. They booted, could not reach the control plane or ECR, and never joined
the cluster — while EC2 reported them `running`, their status checks green, and
the node group `ACTIVE` with no health issues. **Zombie instances that AWS
believed were healthy and Kubernetes could not see.**

They had to be terminated by hand before the cluster would come back.

> The measured RTO for infra-a is therefore not "twenty minutes". It is **"as long
> as it takes an engineer to understand what is happening and intervene"** —
> which is exactly what `terraform/stacks/infra-b/variables.tf` predicted, in
> writing, before a single measurement was taken.

### Why the RPO is UNKNOWN and not zero

`GET /last` — the endpoint that reports what the database still holds — is served
by the application. Every pod was dead, so nothing was left to answer.

The database itself was `available` throughout, with every row intact. But **we
cannot prove that from inside the experiment**, and an earlier version of the
analysis did the unforgivable thing: it treated an unanswerable question as a
total loss and reported *"76 acknowledged writes lost, RPO 76s"* about a database
that had lost nothing.

An unreadable database means the RPO is unknown. Not zero. Not total loss.
Unknown. `tests/test_analysis.py` now asserts this.

### The observability died with the workload

This is the finding that was not planned, and it may be the most useful one.

| witness | data during the 15-minute outage |
|---|---|
| kube-state-metrics *(in the cluster)* | **3 data points in 90 minutes** |
| Prometheus, Grafana *(in the cluster)* | pod evicted, EBS volume stranded in the dead AZ |
| `chaos/probe.py` *(outside the cluster)* | **578 samples, no gap** |

Every in-cluster observer ran on system nodes inside the target AZ. They died
with it. The Grafana "Pending pods" panel reads **zero** for the entire outage —
not because no pods were pending, but because **nobody was left alive to count
them**.

A dashboard that goes blank at exactly the moment you need it is not a monitoring
system. It is a monitoring system's obituary.

> *"Asking a system to report on its own death produces a suspiciously flattering
> obituary."* — written in `k8s/monitoring/prometheusrule-resilience.yaml` before
> any of this was measured. It is no longer a turn of phrase.

The external probe is why this project has any numbers at all.

---

## infra-b — multi-AZ + DR

| metric | value |
|---|---|
| RTO | _not yet run_ |
| RPO | _not yet run_ |
| Availability during the fault | _not yet run_ |
| Zones serving during the fault | _not yet run_ |

### What it predicts

Karpenter runs **three replicas with a hard anti-affinity across zones**, so the
controller survives in `eu-west-3b`/`3c`. The 34 USD/month third system node —
the line item nobody puts on the invoice — is precisely what buys the difference
between "the autoscaler replaces the lost capacity" and "there is nobody left to
ask".

RDS has a synchronous standby, so a commit is durable in two AZs before it is
acknowledged: **RPO should be exactly zero**, and provably so, because pods in the
surviving zones will still be alive to answer `GET /last` - which is exactly what
infra-a could not do, leaving its RPO permanently unknown.

If infra-b does not survive, that is a far more interesting result than if it
does, and it will be reported as loudly.

---

## The three discarded runs

Kept in `results/infra-a/_discarded/`, with their autopsies. They are not
results, and none of them is in any number above. They are worth reading anyway,
because each one produced a **well-formed, plausible, completely wrong answer**
that nothing in the tooling flagged.

| run | reported | what was actually wrong |
|---|---|---|
| 1 | RTO 1006 s | Recovery came from FIS restarting the instances it stopped — not from the architecture. |
| 2 | RTO 341 s | Karpenter reclaimed the stopped nodes, so FIS could not restart its own; the action failed; and FIS reacts to a failed action by stopping **every** action, including the network disruption. **The fault was truncated from 15 minutes to five.** A shorter outage, reported as a faster recovery. |
| 3 | RTO 288 s | `scope: availability-zone` only cuts traffic *crossing* the AZ boundary. infra-a lives entirely inside it, so nothing crossed — the "dead" zone happily talked to itself, Karpenter launched replacements **inside the dead zone**, and the service was back in 4m48s with eleven minutes of "outage" left to run. **It was not an AZ failure at all.** |

The third one is the one to dwell on. It measured a real thing, correctly and
reproducibly — the wrong thing. Its only symptom was a Grafana panel showing zero
Pending pods, which looked like a broken graph and was in fact the graph honestly
reporting that Karpenter had never been blocked.

**Every number in this file exists because those three were thrown away.**

---

## Known limitations

Stated plainly, because a portfolio that only lists its strengths is advertising.

1. **One run, not a median.** The result is categorical — the system does not
   recover — so a median of three would not add much. But it is one run, and it
   is labelled as one run.

2. **FIS cannot simulate a real AZ loss.** It implements network disruption with
   network ACLs, and NACLs do not filter traffic *within* a subnet. A genuine AZ
   loss also means EC2 refuses to launch there at all — no FIS action can do
   that. **The measured RTO is a lower bound. Reality is worse.**

3. **The witness app is trivial.** No cache to warm, no leader election, no
   long-lived connections to rebuild. A real application adds its own recovery
   time on top of the infrastructure's.

4. **infra-b survives an AZ, not a region.** There is no cross-region story: the
   read replica that would have been one had to go, because AWS refuses to create
   a Postgres replica for an instance whose master password RDS manages. Between
   credential rotation that works and a DR path that was never going to be
   tested, rotation won. See docs/finops-analysis.md.
