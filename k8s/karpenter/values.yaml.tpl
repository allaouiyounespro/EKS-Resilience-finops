# Karpenter Helm values
# owner: allaouiyounespro / portfolio: github.com/allaouiyounespro
#
# Rendered by scripts/bootstrap-cluster.sh. Placeholders:
#   ${CLUSTER_NAME} ${CLUSTER_ENDPOINT} ${INTERRUPTION_QUEUE}

settings:
  clusterName: ${CLUSTER_NAME}
  clusterEndpoint: ${CLUSTER_ENDPOINT}

  # The SQS queue fed by the EventBridge rules in the karpenter terraform module.
  # Without it, Karpenter learns an instance is gone only when the node goes
  # NotReady - roughly 40 seconds later than AWS was willing to tell it.
  interruptionQueue: ${INTERRUPTION_QUEUE}

# No role-arn annotation here, and that absence is the feature: credentials
# arrive via EKS Pod Identity, bound in Terraform where the IAM role lives.
# The only contract this file has to honour is the service account's NAME
# matching the association - break that and Karpenter silently runs with the
# node's role, which can describe instances all day and launch none.
serviceAccount:
  create: true
  name: karpenter

# Two replicas with a hard anti-affinity across zones. This is the least
# glamorous and most important block in the file.
#
# Karpenter is the thing that performs the recovery. If it dies in the same AZ
# that FIS just destroyed, then in infra-b there is nobody left to launch
# replacement capacity, and the measured RTO collapses to whatever infra-a's is -
# not because the topology failed, but because the controller did.
#
# In infra-a this anti-affinity cannot be satisfied at all (there is only one
# zone), so the second replica sits Pending forever. That is not a
# misconfiguration to fix: it is an honest rendering of the fact that infra-a has
# no second failure domain to put a spare controller in.
replicas: 2

affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: topology.kubernetes.io/zone
        labelSelector:
          matchLabels:
            app.kubernetes.io/instance: karpenter
            app.kubernetes.io/name: karpenter

# Karpenter must run on the managed node group, never on nodes it manages itself.
# A controller that can be consolidated away by its own consolidation loop is a
# reliable source of 3am pages.
nodeSelector:
  workload-class: system

tolerations:
  - key: CriticalAddonsOnly
    operator: Exists

podDisruptionBudget:
  name: karpenter
  maxUnavailable: 1

controller:
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      memory: 1Gi

# LOG_LEVEL=info. debug would drown the experiment's signal; error would hide the
# provisioning decisions that are the entire point of reading these logs
# afterwards ("why did it not launch a node in eu-west-3b?").
logLevel: info

# Scrape target for the kube-prometheus-stack. The Karpenter metric that matters
# most here is karpenter_nodeclaims_launched, timestamped against the FIS action
# start - that difference is the autoscaler's true contribution to RTO.
serviceMonitor:
  enabled: true
  additionalLabels:
    release: kube-prometheus-stack
