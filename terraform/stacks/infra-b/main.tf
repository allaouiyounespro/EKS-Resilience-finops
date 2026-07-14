# ---------------------------------------------------------------------------
# stack: infra-b  -  "the one you have to justify to finance"
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
#
# The resilient architecture. Roughly 380 USD/month, so ~200 USD/month more than
# infra-a. Every one of those dollars has a line item and a reason:
#
#   ~64 USD  two extra NAT Gateways    - egress survives losing an AZ
#   ~90 USD  RDS Multi-AZ standby      - RPO goes from "up to 5 minutes" to zero
#   ~30 USD  RDS read replica          - a promotion path for a regional event
#   ~30 USD  a third system node       - Karpenter itself survives the blast
#   ~ 5 USD  cross-AZ data transfer    - the tax you pay for spreading out
#
# The FinOps question this project exists to answer is not "is 380 more than 180"
# - it obviously is. It is: how often does an AZ have to fail before the extra
# 200 USD/month is cheaper than the outage it prevents?
#
# See finops/cost_model.py and docs/finops-analysis.md for the answer.
# ---------------------------------------------------------------------------

module "platform" {
  source = "../../modules/platform"

  name         = var.name
  cost_profile = "multi-az-dr"

  vpc_cidr = var.vpc_cidr

  # Three AZs of subnets, and the workload is allowed to use all three.
  azs          = var.azs
  workload_azs = var.azs

  # One NAT per AZ. Losing one AZ leaves the other two with working egress -
  # which matters more than it sounds, because a node that cannot reach ECR
  # cannot pull the image of the pod you are trying to reschedule onto it.
  single_nat_gateway = false

  kubernetes_version = var.kubernetes_version
  system_node_group  = var.system_node_group

  # Synchronous standby in another AZ: a commit is not acknowledged until it is
  # durable in two places, so an AZ loss costs zero committed transactions.
  db_instance_class          = var.db_instance_class
  db_allocated_storage       = var.db_allocated_storage
  db_multi_az                = true
  db_create_read_replica     = true
  db_backup_retention_period = 7

  # Aim at the AZ holding the RDS writer. Targeting a quiet AZ would be a much
  # more flattering experiment and a much less useful one.
  chaos_target_az        = var.azs[0]
  chaos_duration_minutes = var.chaos_duration_minutes

  cluster_admin_arns          = var.cluster_admin_arns
  cluster_public_access_cidrs = var.cluster_public_access_cidrs

  tags = var.tags
}
