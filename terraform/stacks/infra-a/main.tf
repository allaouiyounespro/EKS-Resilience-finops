# ---------------------------------------------------------------------------
# stack: infra-a  -  "the one that looks fine until it isn't"
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
#
# The cheap architecture. 285 USD/month as measured.
#
#   - all compute and data pinned into a single AZ
#   - one NAT Gateway
#   - single-AZ RDS, no standby: recovery means a point-in-time restore
#   - Karpenter constrained to that one AZ, so it has nowhere to move capacity to
#
# This is not a strawman. It is what a competent engineer ships when the brief is
# "get it running, keep it cheap", and it is what a large fraction of real
# production estates actually look like.
#
# What the experiment found: when the AZ went away, this stack did not come back.
# Karpenter died with it, the ASG's replacement nodes became zombies EC2 called
# healthy, and a human had to intervene. See docs/results.md.
#
# Everything except the resilience settings is identical to infra-b. Compare:
#   diff terraform/stacks/infra-a/terraform.tfvars terraform/stacks/infra-b/terraform.tfvars
# ---------------------------------------------------------------------------

module "platform" {
  source = "../../modules/platform"

  name         = var.name
  cost_profile = "single-az"

  vpc_cidr = var.vpc_cidr

  # Two AZs of subnets because AWS will not build EKS or an RDS subnet group with
  # fewer - but only one of them is ever used for anything.
  azs          = var.azs
  workload_azs = [var.azs[0]]

  # One NAT for the whole VPC. Saves ~64 USD/month against infra-b, and sits in
  # the same AZ as everything else, so it dies with them.
  single_nat_gateway = true

  kubernetes_version = var.kubernetes_version
  system_node_group  = var.system_node_group

  # No standby, no replica. The recovery path is: restore from backup, and wait.
  db_instance_class          = var.db_instance_class
  db_allocated_storage       = var.db_allocated_storage
  db_multi_az                = false
  db_create_read_replica     = false
  db_backup_retention_period = 7

  # There is only one AZ to aim at.
  chaos_target_az        = var.azs[0]
  chaos_duration_minutes = var.chaos_duration_minutes

  cluster_admin_arns          = var.cluster_admin_arns
  cluster_public_access_cidrs = var.cluster_public_access_cidrs

  tags = var.tags
}
