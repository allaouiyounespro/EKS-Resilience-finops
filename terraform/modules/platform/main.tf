# ---------------------------------------------------------------------------
# module: platform
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
# ---------------------------------------------------------------------------

locals {
  # Cost allocation is the whole second half of this project, so the tags that
  # let Cost Explorer split the bill by architecture are not optional decoration.
  # Activate CostProfile as a cost allocation tag in Billing or the FinOps
  # numbers have to be reconstructed by hand from resource ids.
  tags = merge(
    var.tags,
    {
      Project     = "eks-resilience-finops"
      Stack       = var.name
      CostProfile = var.cost_profile
      Owner       = "allaouiyounespro"
      Portfolio   = "github.com/allaouiyounespro"
      ManagedBy   = "terraform"
    },
  )

  # Index of every workload AZ inside the full AZ list, used to pick out the
  # subnets compute is allowed to land in.
  workload_az_indexes = [
    for az in var.workload_azs : index(var.azs, az)
  ]
}

module "vpc" {
  source = "../vpc"

  name         = var.name
  cluster_name = var.name
  cidr         = var.vpc_cidr
  azs          = var.azs

  single_nat_gateway = var.single_nat_gateway

  enable_flow_logs = true

  tags = local.tags
}

locals {
  # Subnets the workload may actually run in. For infra-a this is a one-element
  # list, which is what confines the entire application to a single AZ.
  workload_subnet_ids = [
    for i in local.workload_az_indexes : module.vpc.private_subnet_ids[i]
  ]
}

module "eks" {
  source = "../eks"

  name               = var.name
  kubernetes_version = var.kubernetes_version
  vpc_id             = module.vpc.vpc_id

  # The control plane's ENIs go into every private subnet - AWS requires two AZs
  # and there is no cost or resilience argument for restricting it. The control
  # plane is AWS-managed and already spread across AZs; pretending otherwise
  # would not make infra-a any more single-AZ than it already is.
  subnet_ids = module.vpc.private_subnet_ids

  # The system node group, on the other hand, is confined to the workload AZs.
  # This is the line that makes infra-a a genuine SPOF.
  node_subnet_ids   = local.workload_subnet_ids
  system_node_group = var.system_node_group

  endpoint_public_access = true
  public_access_cidrs    = var.cluster_public_access_cidrs
  cluster_admin_arns     = var.cluster_admin_arns

  tags = local.tags
}

module "karpenter" {
  source = "../karpenter"

  cluster_name   = module.eks.cluster_name
  node_role_name = module.eks.node_role_name

  tags = local.tags
}

# AWS Load Balancer Controller prerequisites. The controller reconciles the
# Gateway API objects in k8s/workload/ into an actual ALB - without this role
# the Gateway sits with an empty address forever, and nothing errors.
module "lbc" {
  source = "../lbc"

  cluster_name = module.eks.cluster_name

  tags = local.tags
}

module "rds" {
  source = "../rds"

  name   = var.name
  vpc_id = module.vpc.vpc_id

  # The subnet group must span every private subnet - AWS rejects a group in
  # fewer than two AZs even for a single-AZ instance. Placement is then forced
  # back into the workload AZ by availability_zone below.
  subnet_ids = module.vpc.private_subnet_ids

  allowed_security_group_ids = [module.eks.cluster_security_group_id]

  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage

  multi_az            = var.db_multi_az
  create_read_replica = var.db_create_read_replica

  # Pin the single-AZ writer next to the nodes. Null when Multi-AZ, since RDS
  # then owns placement itself.
  availability_zone = var.db_multi_az ? null : var.workload_azs[0]

  backup_retention_period = var.db_backup_retention_period

  tags = local.tags
}

module "fis" {
  source = "../fis"

  name         = var.name
  cluster_name = module.eks.cluster_name

  # For a Multi-AZ database the target is wherever RDS put the writer, not
  # wherever we guessed it would be.
  #
  # You cannot pin a Multi-AZ instance's AZ - the API rejects it - so RDS chooses,
  # and it chose eu-west-3c on the first infra-b apply while chaos_target_az said
  # eu-west-3a. Killing 3a would have missed the database entirely, and the
  # failover this stack exists to measure would never have fired. The run would
  # have completed, reported a number, and measured nothing.
  #
  # Targeting the writer's AZ also keeps reset-stack.sh honest: a Multi-AZ
  # failover swaps writer and standby between the two AZs RDS picked, so failing
  # back always lands on this one.
  target_az          = var.db_multi_az ? module.rds.availability_zone : var.chaos_target_az
  target_subnet_arns = [module.vpc.subnet_arns_by_az[var.db_multi_az ? module.rds.availability_zone : var.chaos_target_az]]

  db_instance_arn = module.rds.db_instance_arn

  # Only attach the failover action where there is a standby to fail over to.
  # Forcing a reboot on infra-a's lone instance would inject an outage that a
  # real AZ failure causes by a different mechanism, and would make infra-a look
  # worse for the wrong reason.
  enable_rds_failover = var.db_multi_az

  duration_minutes = var.chaos_duration_minutes

  # Deliberately empty: this runs in a throwaway account where the blast radius
  # is the entire point. A production experiment would wire the app's error-rate
  # alarm in here so FIS aborts itself if the fault escapes its predicted scope.
  stop_condition_alarm_arns = []

  tags = local.tags
}
