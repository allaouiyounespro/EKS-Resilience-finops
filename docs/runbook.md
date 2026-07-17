# Runbook — AZ-Failure Chaos Experiment

| | |
|---|---|
| **Service** | eks-resilience-finops (witness platform, both stacks) |
| **Owner** | allaouiyounespro · [github.com/allaouiyounespro](https://github.com/allaouiyounespro) |
| **Document version** | 1.2 |
| **Last reviewed** | 2026-07-17 — after both campaigns |
| **Review cadence** | before every experiment campaign, and after any change to `terraform/modules/fis` |
| **Audience** | the engineer running the experiment; assumes working AWS + kubectl fluency |
| **Escalation** | none — lab account. In production this row is the most important line of the document. |

> **Scope.** This runbook covers running a deliberate AZ-failure experiment
> against a **disposable lab account**, aborting it, and tearing it down. It is
> written in production style on purpose: an experiment that destroys an
> availability zone deserves the same discipline as the incident it simulates.

* * *

## 1. Severity model

The experiment produces states that look like incidents. Classify before
reacting — half of "the experiment went wrong" reports are the experiment going
right.

| State | Classification | Action |
|---|---|---|
| infra-b degraded to 4/6 replicas during the fault window | **Expected** | none — this is the finding |
| infra-a total outage during the fault window | **Expected** | none — this is the finding |
| `WitnessTotalOutage` firing on **infra-b** | **SEV-2 equivalent** | the $222/month bought nothing; capture everything, § 6 |
| Fault window elapsed +10 min, infra-a still down | **Expected-degraded** | AZ restoration is AWS's clock, not yours; keep observing |
| Spend anomaly (Karpenter node count climbing) | **SEV-2 equivalent** | § 5 abort, then § 7.3 |
| Blast radius outside the target stack | **SEV-1 equivalent** | § 5 abort immediately, then investigate the FIS target selectors |

* * *

## 2. Pre-flight — account level, once

Do these **before the first `terraform apply`**. Two of them are irreversible in
the sense that skipping them cannot be repaired retroactively.

- [ ] **Activate cost allocation tags** — `Project`, `Owner`, `CostProfile`.

      ```bash
      aws ce update-cost-allocation-tags-status --region us-east-1 \
        --cost-allocation-tags-status TagKey=Project,Status=Active \
                                      TagKey=Owner,Status=Active \
                                      TagKey=CostProfile,Status=Active
      ```

      Two traps here, and they compound:

      **AWS refuses to activate a tag key it has never seen on a resource.** So
      `CostProfile` — which only exists on stack resources — cannot be activated
      until after the first `terraform apply`. The call above will succeed for
      `Project`/`Owner` and return an error for `CostProfile`, which reads like a
      permissions problem and is not.

      **Activation is not retroactive.** Costs incurred before a tag is active are
      never attributable to it, by any means, ever.

      Together: run the command now, then **run it again right after the first
      apply** to pick up `CostProfile`. Miss the second call and
      `scripts/cost-explorer.sh` cannot split the bill by architecture — which is
      half of what this project claims to do.
- [ ] **Budget alarm** at $100/month on the account. The Karpenter NodePool caps
      runaway scaling at 32 vCPU, but a budget alarm catches everything the cap
      does not — including the stack you forgot to destroy.
- [ ] **State bucket** exists, versioned (a chaos run that dies mid-apply leaves
      state only a previous version can repair):

```bash
aws s3api create-bucket --bucket <bucket> --region eu-west-3 \
  --create-bucket-configuration LocationConstraint=eu-west-3
aws s3api put-bucket-versioning --bucket <bucket> \
  --versioning-configuration Status=Enabled
cp terraform/backend.hcl.example terraform/backend.hcl    # then edit
```

- [ ] **Witness image** built and pushed; `WITNESS_IMAGE` exported.
- [ ] Verify identity and region before anything destructive:
      `aws sts get-caller-identity` — confirm this is the **lab** account. The
      FIS template only targets tagged resources, but "wrong account" is not a
      mistake this document can walk back.

* * *

## 3. Pre-flight — per campaign

- [ ] `make check` green locally (9 Terraform dirs validate, 102 tests pass).
- [ ] `make init plan STACK=<stack>` — read the plan. An unexpected replace on
      the RDS instance means the run starts with an empty ledger.
- [ ] No other experiment running: `aws fis list-experiments --region eu-west-3
      --query 'experiments[?state.status==`running`]'` must be empty.
- [ ] Chart versions in `scripts/bootstrap-cluster.sh` (`KARPENTER_VERSION`,
      `LBC_VERSION`, `GATEWAY_API_VERSION`) checked against the EKS version in
      the stack variables. Bump deliberately, never mid-campaign.

* * *

## 4. Procedure — one campaign

Total wall-clock per stack: **~1 h 45 (infra-a) / ~2 h 15 (infra-b)** for a
3-run campaign, including build and teardown. AWS cost for the whole thing:
**~$5**. The binding constraint is time, not money — EKS create + delete is ~35
min per stack and nothing shortens it.

### 4.1 Build and bootstrap

```bash
make up STACK=infra-a          # terraform apply + bootstrap-cluster.sh
```

Expected terminal states, in order — if one is missed, stop and read the section
of the bootstrap script that announces it:

1. `syncing database credentials` — Secrets Manager → k8s Secret (via stdin; the
   password never appears in `ps` or the terminal)
2. `installing Gateway API CRDs` / `installing AWS Load Balancer Controller`
3. `installing Karpenter` then `applying NodePool (zones: [...])` — **verify the
   zone list**: one zone for infra-a, three for infra-b. A wrong list here
   invalidates the whole run.
4. `installing kube-prometheus-stack` — slowest step; the Prometheus PVC binds
   only after the EBS CSI addon is active
5. `waiting for the workload` — first pods pend 2–4 min while Karpenter launches
   nodes; this is the closest thing to a free rehearsal of the recovery
6. `waiting for the Gateway to be assigned an address` — ends with the ALB
   hostname. **Record it.**

### 4.2 Verify steady state

```bash
kubectl -n witness get pods -o wide     # 6/6 Ready; note the AZ spread
curl -s http://<gateway-host>/readyz | jq .zone
kubectl -n witness get gateway witness  # PROGRAMMED True
```

For infra-b, confirm the spread is 2/2/2 across zones. A 4/1/1 spread is legal
under `ScheduleAnyway` but weakens the comparison — delete pods until the
scheduler rebalances, or note it in the run log.

### 4.3 Run the campaign

```bash
make campaign STACK=infra-a RUNS=3
```

**Three runs, not one.** RDS failover time varies by tens of seconds between
runs and Karpenter's node launch depends on whatever capacity EC2 happens to
have that minute. A single number from a single run is a coin flip presented as
a measurement. The stack stays up between runs — rebuilding would cost 35 min of
EKS create/delete each time and would measure a *cold* cluster three times
instead of the same cluster three times. Each extra run costs ~30 min and ~$0.20.

Each run is `reset → inject → observe → report`, and the runner is sequenced
deliberately. Do not "help" it:

| Phase | Duration | What it guards |
|---|---|---|
| reset (§ 4.3.1) | 2–5 min | the run starts from the same state run #1 did |
| probes start | — | they must predate the fault or the RTO has no baseline |
| baseline | 60 s | **aborts on a single failed request** — you cannot measure recovery from a state that was never healthy |
| FIS injection | ~15 min | clock anchored to FIS's own `startTime`, not the operator's enter key |
| settle | 10 min | FIS restarting instances is not the service being back; most of infra-a's recovery happens here |
| report | — | writes `results/<stack>/<ts>/result.json`; raw NDJSON is never overwritten |
| cool-down | 2 min | CloudWatch, the ALB target group and Karpenter's consolidation loop all settle |

#### 4.3.1 Why the reset exists — read this before skipping it

`scripts/reset-stack.sh` runs before **every** injection, including the first.
It closes a trap that produces perfectly normal-looking, completely worthless
data:

> Run #1 forces the RDS writer to fail over from `eu-west-3a` to its standby in
> `eu-west-3b`. **The FIS template still targets `eu-west-3a`** — that AZ is
> baked in at `terraform apply` time and does not follow the database.
>
> So run #2 would isolate an AZ that no longer holds the writer. The database is
> never touched. Fewer pods die. The RTO comes out flatteringly low, the
> `result.json` looks entirely normal, and the median across three runs is
> quietly meaningless.
>
> Nothing errors. Nothing warns. That is what makes it dangerous.

The reset fails the writer back to the target AZ, waits for 6/6 replicas, and
**aborts** if the pods ended up packed into fewer zones than the architecture
claims (a previous recovery can leave them concentrated, which would silently
shrink the next run's blast radius).

### 4.4 Record

```bash
python3 -m chaos.aggregate --stack infra-a --markdown results/infra-a/*/result.json
```

The campaign prints this table for you. Paste it into `docs/results.md`, keep the
run directories, note anything anomalous.

**A run that never recovered is not dropped from the median** — it is counted and
flagged, and if non-recovery is the majority outcome the aggregate refuses to
report an RTO at all. Publishing "infra-a recovers in 21 minutes" from a campaign
in which one run never came back would be the most dishonest thing this tooling
could do, so it is made structurally impossible rather than left to discipline.

An unrecorded run is a spent budget with nothing to show.

* * *

## 5. Abort procedure

```bash
aws fis stop-experiment --id <experiment-id> --region eu-west-3
```

FIS lifts the network disruption immediately and restarts stopped instances.
Know what it does **not** undo:

- Killed pods stay killed — Kubernetes reschedules them on its own schedule.
- A completed RDS failover is **not reversed**. The standby is now the writer.
  That is not damage; it is the new steady state, and the next run fails back.
- The probes keep running until their parent script exits — kill the script,
  not just the experiment, or the NDJSON grows a tail of post-abort samples.

If the abort was for blast radius (§ 1, SEV-1 row): before anything else, dump
the experiment log group (`/aws/fis/<stack>`) and the resolved targets
(`aws fis get-experiment`). The target selectors are tag-scoped; the usual root
cause is a tag that leaked onto resources outside the stack.

* * *

## 6. When the run produces something suspicious

| Symptom | Likely story | Check |
|---|---|---|
| RTO = 0 on infra-a | The fault never landed. | `zones_serving_during_fault` in `result.json` — if the target AZ appears, the FIS selector matched nothing. `empty_target_resolution_mode = "fail"` should have refused the start; if it ran anyway, the node tags are wrong. |
| Every pod reports `zone=unknown` | resolve-zone initContainer failed, or someone ran `envsubst` over the deployment manifest and blanked `${NODE_NAME}`. | The run is worthless — "survivors took over" and "doomed AZ answered" are indistinguishable. `tests/test_manifests.py` guards the envsubst path. |
| Gateway has no address | LBC missing, or its Pod Identity association points at a service account whose **name** does not match the Helm release's. | `kubectl -n kube-system logs deploy/aws-load-balancer-controller` |
| Prometheus PVC Pending | EBS CSI addon missing or gp3 StorageClass not applied. | `kubectl describe pvc -n monitoring` — an event blaming the StorageClass usually means the driver. |
| Pods Pending, zero node launches, **infra-a** | **Expected. That is the finding.** | `KarpenterCannotProvision` should be firing. |
| Pods Pending, zero node launches, **infra-b** | NodePool zone list or subnet discovery tags. | `kubectl logs -n kube-system deploy/karpenter | grep -i "no instance type"` |
| infra-b RTO ≈ infra-a RTO | Karpenter controller died with the AZ — check where its replicas were scheduled. | The measurement is of a broken control loop, not the topology. Re-run after confirming the anti-affinity held. |
| Run #2 or #3 much faster than run #1 | **The reset was skipped or failed.** The RDS writer is no longer in the targeted AZ, so the fault missed the database entirely. | `aws rds describe-db-instances --query 'DBInstances[0].AvailabilityZone'` must equal `fis_target_az`. Discard the run — it is not comparable. |
| Aggregate says "RTO NOT MEASURABLE" | The majority of runs never recovered. | Not a tooling bug. It is the aggregate refusing to report a median of the luckiest runs. For infra-a this may be the honest answer. |
| RPO > 0 on infra-b | The most interesting possible result — Multi-AZ says this cannot happen. | Verify the writer only recorded `committed: true` on genuine 200s, then `aws rds describe-events` to confirm the failover actually occurred. Escalate to a re-run before publishing. |
| NetworkPolicy suspected (timeouts, nothing in logs) | Egress deny eating DNS or 443. | `kubectl -n witness describe networkpolicy witness-allow`; remember enforcement needs `enableNetworkPolicy` in the CNI addon config. |

* * *

## 7. Teardown

### 7.1 Standard

```bash
make down STACK=infra-a
```

`make down` deletes the **Gateway first and waits**. The ALB belongs to the LB
Controller, not Terraform; skip this and `terraform destroy` hangs 20 minutes on
a VPC whose ENIs are still held by a load balancer it cannot see, then fails.

### 7.1b When the graceful teardown fails — and after a real fault, it will

Observed on the infra-a campaign. **The Gateway deletion itself timed out**,
because the cluster was still broken from the experiment. The ALB survived, kept
its ENIs in the subnets, and `terraform destroy` failed on `DependencyViolation`
— twice.

The tidy path assumes a healthy cluster. After a chaos run, a healthy cluster is
precisely what you do not have. Plan for this.

Three orphans, none of them known to Terraform, every one created by a controller:

| orphan | created by | what it blocks |
|---|---|---|
| the ALB | AWS Load Balancer Controller | the subnets |
| a Karpenter instance | Karpenter | the subnets |
| 3 security groups (`k8s-traffic-*`, `k8s-witness-*`, `eks-cluster-sg-*`) | LB Controller, VPC CNI, EKS | **the VPC itself** |

The security groups are the sting in the tail: they cross-reference each other,
so none can be deleted until the rules are revoked first.

```bash
./scripts/panic.sh --destroy          # ALB, instances, clusters, databases, NAT

# then, if the VPC still refuses to go:
VPC=<vpc-id>
SGS=$(aws ec2 describe-security-groups --region eu-west-3 \
  --filters "Name=vpc-id,Values=$VPC" \
  --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text)

for sg in $SGS; do
  aws ec2 describe-security-groups --region eu-west-3 --group-ids "$sg" \
    --query 'SecurityGroups[0].IpPermissions' --output json > /tmp/in.json
  aws ec2 revoke-security-group-ingress --region eu-west-3 --group-id "$sg" \
    --ip-permissions file:///tmp/in.json 2>/dev/null || true
  aws ec2 delete-security-group --region eu-west-3 --group-id "$sg"
done

terraform -chdir=terraform/stacks/<stack> destroy -auto-approve
```

`panic.sh` works here for exactly the reason it was written: it reads **AWS's**
view of the world rather than Terraform's, and the moment you need it is, by
definition, the moment those two have diverged.

### 7.2 Verify nothing survived

```bash
aws eks list-clusters --region eu-west-3
aws rds describe-db-instances --region eu-west-3 --query 'DBInstances[].DBInstanceIdentifier'
aws ec2 describe-nat-gateways --region eu-west-3 \
  --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'
aws elbv2 describe-load-balancers --region eu-west-3 --query 'LoadBalancers[].LoadBalancerName'
aws ec2 describe-instances --region eu-west-3 \
  --filters "Name=tag:Project,Values=eks-resilience-finops" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId'
```

All five must return empty. The instance query works **because** the launch
template and the EC2NodeClass tag every instance — untagged compute is exactly
how forgotten resources hide.

### 7.3 Emergency cost stop

Suspected runaway (nodes climbing, § 1): scale the NodePool to zero before
debugging — `kubectl patch nodepool witness --type merge -p '{"spec":{"limits":{"cpu":"0"}}}'`
stops new launches while leaving the evidence running.

Both stacks left up cost **~$793/month (~$26/day)**. The meter does not care
that the laptop is closed.

* * *

## 8. Post-run

- [ ] `docs/results.md` updated from `result.json`; raw NDJSON directory kept
- [ ] `./scripts/cost-explorer.sh` after 24–48 h — reconcile actual spend
      against the model; tens-of-percent disagreement means a missing line item
- [ ] `make finops-verify` — fails if `finops/shapes.yaml` drifted from what was
      actually deployed
- [ ] Anything that surprised you goes into § 6 of this document. A runbook that
      does not grow after a run was not being used.
