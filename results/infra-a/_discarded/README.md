# Discarded runs

owner: allaouiyounespro

Three runs, none usable, kept as evidence of the method rather than as results.
Neither number below belongs in a median, and neither should be quoted.

| run | RTO reported | why it is not usable |
|---|---|---|
| `20260714T170458Z` | 1006 s | Injection was valid, but recovery came from FIS restarting the instances it had stopped - not from the architecture. |
| `20260714T173432Z` | 341 s | **The fault was truncated.** Karpenter reclaimed the stopped nodes; FIS could not restart its own instances; the `stop-instances` action failed; and FIS reacts to a failed action by stopping *every* action, including the network disruption. The outage lasted ~5 minutes instead of 15. |
| `20260714T180305Z` | 288 s | **The fault was not an AZ failure.** `scope: availability-zone` only cuts traffic *crossing* the AZ boundary. infra-a lives entirely inside the target AZ, so nothing it does crosses one - the "dead" zone could still talk to itself. Karpenter launched replacement nodes *in the dead zone*, they joined, and the service was back in 4m48s with eleven minutes of "outage" still to run. |

## Why the third one is the most instructive

It reported a real, correct, reproducible number - for the wrong question. It
measured "every node was stopped once, how fast does Karpenter replace them",
which is a node-failure test. It would have been published as an AZ-failure RTO.

Nothing errored. The JSON was well-formed. The dashboard was green. The only
symptom was a Pending-pods panel stuck at zero - which looked like a broken
panel, and was in fact the graph honestly reporting that Karpenter had never been
blocked at all.

Two fixes, both in `terraform/modules/fis`:

- `startInstancesAfterDuration` removed: it raced with Karpenter's node
  reclamation and let FIS abort its own experiment.
- `scope` changed from `availability-zone` to `all`: the target subnets are now
  cut off from the control plane, the NAT and ECR, so replacement capacity cannot
  join and the outage lasts as long as the fault.
