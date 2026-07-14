# Architecture

owner: allaouiyounespro · portfolio: github.com/allaouiyounespro

Every resilience decision in this repository, what it costs, and what it buys.
The ones worth reading are the ones that are counter-intuitive, so those come
first.

---

## The decisions that are not obvious

### "Single-AZ" is a lie you cannot build

AWS refuses to create an EKS control plane, or an RDS DB subnet group, with
subnets in fewer than two AZs. A literally single-AZ VPC does not exist as a
buildable thing.

So infra-a is not single-AZ at the topology level — it *cannot* be. What it is
instead is a VPC that spans two AZs and then pins **all compute and all data into
one of them**. The SPOF lives in placement, not in topology:

- the system node group gets `node_subnet_ids = [subnet_a]`
- the Karpenter NodePool permits exactly one zone
- the RDS instance is pinned with `availability_zone = az_a`
- the single NAT Gateway sits in AZ a

The second AZ exists, holds two empty subnets, and carries nothing. That is the
honest rendering of the architecture, and it is why `terraform/modules/platform`
separates `azs` (the subnet footprint AWS forces on you) from `workload_azs`
(where things are actually allowed to run).

Collapsing those two variables would silently spread infra-a's nodes across both
AZs, and the single-AZ architecture under test would quietly stop being
single-AZ — while every dashboard stayed green.

### The third system node is the most important $17 in the project

infra-b runs three system nodes, one per AZ. infra-a runs two, both in the same AZ.

That third node is not about capacity. It is what keeps the **Karpenter
controller** alive through the AZ failure.

Karpenter is the thing that performs the recovery. If it dies in the same blast
as the workload, there is nothing left to launch replacement capacity, and the
measured RTO is not "90 seconds" — it is "however long until a human notices."
Every other resilience dollar in infra-b is contingent on this one.

The Helm values give Karpenter two replicas with a **hard** anti-affinity across
zones. In infra-a that constraint cannot be satisfied — there is only one zone —
so the second replica sits `Pending` forever. That is not a bug to fix. It is an
honest rendering of the fact that infra-a has no second failure domain to put a
spare controller in.

### Karpenter is not *slow* in infra-a. It is *powerless*.

This is the sharpest finding available from the experiment, and it is worth being
precise about.

The NodePool's `requirements` pin `topology.kubernetes.io/zone` to the permitted
zones. In infra-a that list has one entry. When FIS destroys that zone, Karpenter
sees unschedulable pods and tries to launch capacity for them — exactly as it does
in infra-b. Every launch fails, because the only zone it is permitted to use no
longer exists.

No amount of autoscaler tuning fixes a topology with nowhere to go. The
`KarpenterCannotProvision` alert in `k8s/monitoring/prometheusrule-resilience.yaml`
exists to say this out loud.

### Liveness must not touch the database

`/healthz` (liveness) never opens a DB connection. `/readyz` (readiness) always does.

Getting this backwards is the most common way to turn a *survivable* RDS failover
into a cluster-wide crash-loop: every pod fails liveness simultaneously, every pod
restarts simultaneously, and the outage you measure is one you caused. infra-b's
RTO would be inflated with entirely self-inflicted damage, and the Multi-AZ spend
would look like it bought nothing.

Liveness answers "is this process wedged". Readiness answers "should traffic come
here". They are different questions and they need different probes.

### `whenUnsatisfiable: ScheduleAnyway`, not `DoNotSchedule`

The pod topology spread constraint uses `ScheduleAnyway`.

With `DoNotSchedule`, during the fault the scheduler would *refuse* to place
replacement pods into the surviving AZs — because doing so would breach the max-skew
against the dead zone. The constraint would enforce the very outage it exists to
survive.

### Gateway API, and the cross-zone trap it retired

The workload is fronted by a Gateway + HTTPRoute reconciled into an ALB by the
AWS Load Balancer Controller — not by an Ingress, and not by the annotated
LoadBalancer Service an earlier revision used.

Two reasons, one architectural and one financial:

- **Typed fields over annotations.** The old NLB Service carried nine
  `service.beta.kubernetes.io/*` annotations; a typo in any of them was silently
  ignored. Gateway API puts the same decisions into versioned fields the API
  server validates, and the AWS-only knobs (scheme, health checks, target type)
  live in two `gateway.k8s.aws` CRDs that are equally typed. The Gateway also
  makes route attachment an explicit grant (`allowedRoutes: Same`) instead of
  Ingress's free-for-all.

- **The cross-zone trap.** On an NLB, cross-zone routing is off by default and
  billed as inter-AZ transfer when on — the exact ~$5/month line a cost review
  deletes without realising that during an AZ failure the NLB node in the dead
  zone then blackholes its share of traffic, capping availability at 2/3 and
  writing off the entire $200/month Multi-AZ spend. ALB cross-zone routing is
  always on and free at the load-balancer layer. The trap is not avoided by
  vigilance anymore; it is gone.

### Pod Identity, not IRSA

Every controller that talks to AWS (Karpenter, the LB Controller, the EBS CSI
driver) gets its role through an EKS Pod Identity association, not an IRSA trust
policy.

IRSA requires an OIDC provider, a TLS fingerprint of its certificate, and a trust
policy whose two `StringEquals` conditions must exactly match the service account
namespace and name — rename either and the controller gets `AccessDenied` on every
call, with nothing pointing at the trust policy. Pod Identity moves that binding
into a first-class AWS resource that Terraform owns, so the role and its binding
live and change together. Dropping IRSA also deleted the `tls` provider and the
OIDC resources from every module: less to build, less to audit, less to break.

### IMDSv2 everywhere, and why the two node tiers differ by one hop

The managed node group runs behind a launch template that sets
`http_tokens = "required"` — without it, any pod that can reach `169.254.169.254`
can steal the node's IAM credentials with one curl. The same launch template's
`tag_specifications` are what actually put tags on the EC2 instances, volumes and
ENIs: tags on the node group resource itself never propagate, and untagged
instances are invisible to the Cost Explorer queries the FinOps half depends on.

The hop limit differs by tier, deliberately. System nodes run at hop limit 2
because the EBS CSI driver reads instance metadata from a pod network namespace —
at hop 1 its requests die silently and every PVC mount fails with an error that
names neither IMDS nor the hop limit. Karpenter's application nodes stay at hop
limit 1: the witness has no business talking to IMDS at all, and hop 1 makes that
a property of the network rather than a hope.

### Secrets: KMS envelope encryption, and nothing on argv

Kubernetes Secrets are envelope-encrypted with a customer-managed KMS key
(`encryption_config` on the cluster). The DB password travels from Secrets
Manager to the cluster through a pipe — never as a `--from-literal` argument,
because anything in argv is world-readable in `/proc/*/cmdline` for as long as
the process runs. The Grafana admin password is generated, handed to Helm via a
file descriptor, and never printed; it is retrieved from the Secret the chart
writes, not from terminal scrollback.

### NetworkPolicy, enforced by the CNI that ships with the cluster

The witness namespace runs default-deny with explicit allows: ALB and Prometheus
in; Postgres, DNS and the API server out. Enforcement is the VPC CNI's native
eBPF agent, switched on by one flag in the addon configuration
(`enableNetworkPolicy`) — a flag worth remembering, because without it every
NetworkPolicy in the cluster is parsed, stored, and silently ignored.

### The Multi-AZ standby is the only thing that buys RPO = 0

RDS Multi-AZ is **exactly 2×** the instance and storage bill — not "about" 2×. AWS
runs a full synchronous standby and charges for it as a second instance.

What that buys: a commit is not acknowledged until the WAL record is durable in
**both** AZs. So an AZ loss costs zero committed transactions. RPO = 0, by
construction, not by luck.

Without it, infra-a's only recovery path is a point-in-time restore, and RDS ships
transaction logs to S3 roughly every 5 minutes. The floor on infra-a's RPO is
therefore "up to 5 minutes of committed transactions, gone" — and the RTO is however
long a PITR takes, which is tens of minutes.

The read replica in infra-b contributes **nothing** to RPO (it is asynchronous). It
is the manual promotion path for a region-level event, and a read-scaling story. It
is listed honestly as such in the cost model rather than being smuggled in as part
of the RPO=0 claim.

---

## Guardrails

Things that exist to stop the experiment from destroying more than intended.

| Guardrail | Where | Why |
|---|---|---|
| `empty_target_resolution_mode = "fail"` | `modules/fis` | An experiment that resolves zero targets must refuse to start. Otherwise it reports SUCCESS having injected nothing, and the resulting RTO of 0 means the tooling broke — not that the architecture is good. |
| Karpenter `limits: cpu 32` | `k8s/karpenter/nodepool.yaml.tpl` | A pod stuck Pending in a crash-loop can drive an unbounded autoscaler to launch instances indefinitely. The first sign is the invoice. |
| `instance-size In [large, xlarge]` | same | Without a cap, Karpenter may satisfy six small pods with one large node — cheaper, and catastrophic: it concentrates the entire workload onto one node in one AZ and rebuilds the SPOF infra-b pays to avoid. |
| `consolidateAfter: 5m` | same | During recovery, pod counts swing for minutes. An eager consolidator would delete the nodes it just created, fighting the recovery it is supposed to be performing. |
| PDB `minAvailable: 4` of 6 | `k8s/workload/40-pdb.yaml` | Permits one AZ's worth (2) to be voluntarily drained. Setting it to 6 would be *worse*: Karpenter could never drain a node, consolidation would deadlock, and the cluster would fill with undrainable nodes. |
| Baseline abort | `scripts/run-experiment.sh` | If any request fails *before* the fault is injected, the run aborts. You cannot measure a recovery from a state that was never healthy. |
| Anchoring to FIS's `startTime` | `scripts/run-experiment.sh` | Not to when the operator pressed enter. The gap is routinely 10–20s of API latency, and charging it to the architecture would be flattering nonsense. |

The one guardrail deliberately **left off**: `stop_condition_alarm_arns = []`. This
runs in a throwaway account where the blast radius is the point. A production
experiment would wire the application's error-rate alarm in here so FIS aborts
itself if the fault escapes its predicted scope. The empty list is an explicit
opt-in, not a default.

---

## Why no Helm release lives in Terraform

The `karpenter` and `lbc` modules provision IAM, the SQS interruption queue and
the instance profile — and stop there. Both Helm releases, the Gateway API CRDs
and every Kubernetes object are applied by `scripts/bootstrap-cluster.sh`.

Wiring the `helm`/`kubernetes` providers into the root module would make every
`terraform plan` depend on the cluster's API server being reachable — which is
precisely the thing the chaos experiment takes away.

A plan that fails because the AZ under test is down is a plan that cannot be used
to fix it.
