# owner: allaouiyounespro / portfolio: github.com/allaouiyounespro
#
# Rendered by scripts/bootstrap-cluster.sh via envsubst. Placeholders:
#   ${CLUSTER_NAME}      EKS cluster name, also the karpenter.sh/discovery tag
#   ${INSTANCE_PROFILE}  instance profile from the karpenter terraform module
#   ${ZONES_JSON}        JSON array of the AZs the workload may occupy
#
# ${ZONES_JSON} is the whole experiment in one variable:
#
#   infra-a -> ["eu-west-3a"]
#   infra-b -> ["eu-west-3a","eu-west-3b","eu-west-3c"]
#
# When FIS destroys eu-west-3a, Karpenter's response is identical in both cases:
# it sees unschedulable pods and tries to launch capacity for them. In infra-b it
# has two other zones to launch into and does so in ~40s. In infra-a the only
# permitted zone is the one that no longer exists, so every launch attempt fails,
# the pods stay Pending, and the RTO is bounded not by Karpenter but by how long
# AWS takes to bring the AZ back.
#
# Be precise about what this shows: Karpenter is not slower in infra-a, it is
# *powerless*. No amount of autoscaler tuning fixes a topology with nowhere to go.
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: witness
  labels:
    owner: allaouiyounespro
spec:
  # AL2023 rather than AL2: faster boot, and boot time is a direct addend in the
  # RTO. Every second shaved off node startup is a second off the recovery.
  amiFamily: AL2023

  amiSelectorTerms:
    - alias: al2023@latest

  # We hand Karpenter a profile rather than a role. It can create and manage its own
  # profile if given a role, but that puts an IAM resource outside Terraform's
  # state - it would survive `terraform destroy` and collide with the next apply.
  # The profile is created by the karpenter module and passed in here.
  instanceProfile: ${INSTANCE_PROFILE}

  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER_NAME}

  securityGroupSelectorTerms:
    - tags:
        kubernetes.io/cluster/${CLUSTER_NAME}: owned

  # Tag everything Karpenter launches. Two reasons, and neither is cosmetic:
  #   - FIS selects its victims by the kubernetes.io/cluster tag, and an untagged
  #     Karpenter node would silently escape the blast radius, quietly serving
  #     traffic and making the architecture look better than it is
  #   - Cost Explorer splits the bill by these tags, and Karpenter nodes are a
  #     large slice of it
  tags:
    karpenter.sh/discovery: ${CLUSTER_NAME}
    Project: eks-resilience-finops
    Owner: allaouiyounespro
    Portfolio: github.com/allaouiyounespro

  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 1
    httpTokens: required

  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 30Gi
        volumeType: gp3
        encrypted: true
        deleteOnTermination: true
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: witness
  labels:
    owner: allaouiyounespro
spec:
  template:
    metadata:
      labels:
        workload-class: app
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: witness

      # Keeps system workloads (Karpenter itself, CoreDNS, Prometheus) off these
      # nodes. If the Karpenter controller could schedule onto a node Karpenter
      # manages, an AZ failure could take out the controller along with the
      # workload - and then nothing is left to perform the recovery.
      taints:
        - key: workload
          value: app
          effect: NoSchedule

      requirements:
        # THE line. Everything else in this file is plumbing.
        - key: topology.kubernetes.io/zone
          operator: In
          values: ${ZONES_JSON}

        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]

        - key: kubernetes.io/os
          operator: In
          values: ["linux"]

        # On-demand only. Spot would be ~70% cheaper and would wreck the
        # experiment: a Spot reclaim mid-run is indistinguishable in the metrics
        # from the AZ failure being injected, and the RTO measurement would be
        # measuring AWS's capacity market instead of the architecture.
        #
        # In a real cost-optimised cluster this is exactly where Spot belongs.
        # The FinOps model quantifies what that would save - see finops/README.md.
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]

        # An explicit allowlist rather than category/generation/size predicates.
        #
        # The predicate version of this block (category in c/m/r, generation > 5,
        # size in large/xlarge) reads more elegantly and costs 2.2x more. Its
        # cheapest match is c6i.large at ~76 USD/month, and infra-b needs three
        # of them - one per AZ, because an EC2 instance lives in exactly one AZ
        # and you cannot spread pods across three zones with two nodes. That is
        # 228 USD/month of compute to serve a workload doing one request a second.
        #
        # Burstable is the right answer for this tier and saying so is the whole
        # point of a FinOps project: the witness pods request 100m CPU and idle
        # far below the t3 baseline, so credits never deplete. They would be the
        # wrong answer for a latency-sensitive tier, and a genuinely bad one for
        # anything CPU-bound - burstable failure modes are miserable to debug.
        #
        # Karpenter picks the cheapest instance that fits, so in practice this
        # resolves to t3.medium. The larger types stay in the list as headroom if
        # the workload is ever scaled up, and they cap the size: without an upper
        # bound Karpenter would happily satisfy six small pods with one big node -
        # cheaper, and catastrophic here, because it would concentrate the entire
        # workload into a single AZ and quietly rebuild the SPOF that infra-b
        # exists to remove.
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["t3.medium", "t3.large", "c6i.large", "m6i.large"]

  disruption:
    # WhenEmptyOrUnderutilized is Karpenter's cost-saving mode: it actively
    # consolidates pods onto fewer nodes.
    consolidationPolicy: WhenEmptyOrUnderutilized

    # Raised from the 30-second default. During recovery, pod counts swing
    # wildly for a couple of minutes; an eager consolidator would start deleting
    # the very nodes it just created, fighting the recovery it is supposed to be
    # performing. Consolidation is a cost feature, and it must not run while the
    # system is still converging.
    consolidateAfter: 5m

    budgets:
      # At most one node may be voluntarily disrupted at a time. Consolidation
      # that drains three nodes at once looks great on the bill and is
      # indistinguishable from an outage to whoever is holding the pager.
      - nodes: "1"

  limits:
    # A hard ceiling on what Karpenter may spend. This is the single most
    # important guardrail in the file: without it, a pod stuck Pending in a
    # crash-loop can drive Karpenter to launch instances indefinitely, and the
    # first sign is the invoice. A resilience experiment that ends in a runaway
    # autoscaler is a very expensive way to learn about limits.
    cpu: "32"
    memory: 128Gi
