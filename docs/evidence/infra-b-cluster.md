# Cluster evidence — infra-b, captured live

owner: allaouiyounespro

Captured with `kubectl` and `aws` against the running infra-b cluster on
2026-07-17, after three chaos runs and before teardown. These are the claims the
architecture makes, checked against the cluster rather than against a diagram.

## Pods spread 2/2/2 across three AZs

```
eu-west-3a: 2 pods
eu-west-3b: 2 pods
eu-west-3c: 2 pods
```

Not the default. It took `DoNotSchedule` + `minDomains` + `nodeTaintsPolicy: Honor`
together - see the constraint at the bottom of this file, and docs/results.md for
what each one fixes.

## Karpenter survives an AZ loss: two replicas, two zones

```
karpenter-75d74cc857-6cw4j  eu-west-3a
karpenter-75d74cc857-zh8tj  eu-west-3c
```

This is what the third system node buys. In infra-a the second replica sits
Pending forever - one zone, nowhere to put it - and when the AZ died, Karpenter
died with the workload and nothing was left to replace it.

## Prometheus survives: two replicas, two zones

```
prometheus-kube-prometheus-stack-prometheus-0  eu-west-3b
prometheus-kube-prometheus-stack-prometheus-1  eu-west-3a
```

infra-a ran one replica. It died with its AZ, its EBS volume was stranded there,
and the dashboard went blank at exactly the moment anyone would have looked at it.

## The database and the fault

```
{
    "writer_az": "eu-west-3c",
    "standby_az": "eu-west-3b",
    "multi_az": true,
    "class": "db.t3.small"
}
FIS currently targets: eu-west-3b
```

**These two disagree right now, and that is correct.** The template is re-pointed
by `scripts/reset-stack.sh` immediately before each run, from
`module.rds.availability_zone`. Run 3's fault then forced the writer onto its
standby, so the writer moved *after* the template was set. Run 4's reset would
realign them before injecting anything - and refuse to run if it could not.

A Multi-AZ instance cannot be pinned to an AZ; RDS chooses. So the fault follows
the database rather than the database being dragged to the fault - which was the
original design, and did not work: two forced failovers reported "completed" in
the RDS event log and left the writer exactly where it started.

## db.t3.small, and not by choice

On the day this ran, AWS had no capacity to sell the resilient architecture in
eu-west-3. `db.t4g.small` had none in the standby AZ - RDS gave up building the
standby, put the instance back to `available` as single-AZ, and reported success,
twice. `db.t4g.medium` was rejected outright. Only the x86 pool had room.

`describe-orderable-db-instance-options` listed all of them as available in all
three AZs. Declared availability is not capacity, and only one of the two has an API.

## What infra-b does NOT do by itself

Every run left a zombie: the ASG replaces the system node in the dead AZ, that
instance boots while the AZ is still cut off, never joins, and stays - `running` in
EC2, green status checks, node group `ACTIVE` with no health issues, unknown to
Kubernetes. Nothing in AWS reconciles it.

After run 3 the system tier was 2/3 and `prometheus-0` sat Pending, because its
EBS volume was stranded in the AZ whose system node was a zombie. Terminating the
zombie brought both back within minutes.

So the honest claim is narrower than "infra-b self-heals":

> **infra-b stays up through an AZ failure without intervention. It does not
> restore its own redundancy without one.**

It survives the next failure only if someone cleared the last one. That is a real
operational cost, it is invisible from every AWS console, and it is why
`reset-stack.sh` reaps zombies before each run rather than trusting the platform.

## The constraint that makes the spread real

```yaml
labelSelector:
  matchLabels:
    app.kubernetes.io/name: witness
maxSkew: 1
minDomains: 3
nodeTaintsPolicy: Honor
topologyKey: topology.kubernetes.io/zone
whenUnsatisfiable: DoNotSchedule
```
