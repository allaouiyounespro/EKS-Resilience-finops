# Runbook — AZ-Failure Chaos Experiment

| | |
|---|---|
| **Service** | eks-resilience-finops (witness platform, both stacks) |
| **Owner** | allaouiyounespro · [github.com/allaouiyounespro](https://github.com/allaouiyounespro) |
| **Document version** | 1.1 |
| **Last reviewed** | 2026-07-14 |
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
| `WitnessTotalOutage` firing on **infra-b** | **SEV-2 equivalent** | the $193/month bought nothing; capture everything, § 6 |
| Fault window elapsed +10 min, infra-a still down | **Expected-degraded** | AZ restoration is AWS's clock, not yours; keep observing |
| Spend anomaly (Karpenter node count climbing) | **SEV-2 equivalent** | § 5 abort, then § 7.3 |
| Blast radius outside the target stack | **SEV-1 equivalent** | § 5 abort immediately, then investigate the FIS target selectors |

* * *

## 2. Pre-flight — account level, once

Do these **before the first `terraform apply`**. Two of them are irreversible in
the sense that skipping them cannot be repaired retroactively.

- [ ] **Activate cost allocation tags** — Billing console → Cost allocation tags
      → activate `Project` and `CostProfile`. **Not retroactive.** Costs incurred
      before activation are never attributable, and the FinOps reconciliation
      (`scripts/cost-explorer.sh`) will return nothing for that period.
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

- [ ] `make check` green locally (9 Terraform dirs validate, 83 tests pass).
- [ ] `make init plan STACK=<stack>` — read the plan. An unexpected replace on
      the RDS instance means the run starts with an empty ledger.
- [ ] No other experiment running: `aws fis list-experiments --region eu-west-3
      --query 'experiments[?state.status==`running`]'` must be empty.
- [ ] Chart versions in `scripts/bootstrap-cluster.sh` (`KARPENTER_VERSION`,
      `LBC_VERSION`, `GATEWAY_API_VERSION`) checked against the EKS version in
      the stack variables. Bump deliberately, never mid-campaign.

* * *

## 4. Procedure — one experiment run

Total wall-clock: **~55 min** (20 build + 10 bootstrap + 25 experiment).

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

### 4.3 Run

```bash
make experiment STACK=infra-a
```

The runner is sequenced deliberately; do not "help" it:

| Phase | Duration | What it guards |
|---|---|---|
| probes start | — | they must predate the fault or the RTO has no baseline |
| baseline | 60 s | **aborts on a single failed request** — you cannot measure recovery from a state that was never healthy |
| FIS injection | ~15 min | clock anchored to FIS's own `startTime`, not the operator's enter key |
| settle | 10 min | FIS restarting instances is not the service being back; most of infra-a's recovery happens here |
| report | — | writes `results/<stack>/<ts>/result.json`; raw NDJSON is never overwritten |

### 4.4 Record

Paste `result.json` into `docs/results.md`, attach the run directory, note
anything anomalous. An unrecorded run is a spent budget with nothing to show.

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

Both stacks left up cost **~$683/month (~$22/day)**. The meter does not care
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
