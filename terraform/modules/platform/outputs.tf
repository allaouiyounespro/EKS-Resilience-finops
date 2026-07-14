# ---------------------------------------------------------------------------
# module: platform / outputs
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
# ---------------------------------------------------------------------------

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = module.eks.cluster_endpoint
}

output "vpc_id" {
  description = "VPC id."
  value       = module.vpc.vpc_id
}

output "workload_azs" {
  description = "AZs the workload is allowed to run in. Length 1 means single-AZ."
  value       = var.workload_azs
}

output "private_subnet_ids_by_az" {
  description = "Private subnet id per AZ."
  value       = module.vpc.subnet_ids_by_az
}

output "db_endpoint" {
  description = "Postgres writer endpoint."
  value       = module.rds.endpoint
}

output "db_secret_arn" {
  description = "Secrets Manager ARN with the RDS master credentials. Consumed by the app and by the RPO probe."
  value       = module.rds.master_user_secret_arn
}

output "db_multi_az" {
  description = "Whether the database has a synchronous standby."
  value       = module.rds.multi_az
}

output "fis_experiment_template_id" {
  description = "FIS template id. Fed straight to scripts/run-experiment.sh."
  value       = module.fis.experiment_template_id
}

output "fis_target_az" {
  description = "The AZ the experiment takes out."
  value       = module.fis.target_az
}

# ---------------------------------------------------------------------------
# Bootstrap bundle
#
# Everything scripts/bootstrap-cluster.sh needs to render the Karpenter Helm
# values and the EC2NodeClass. Emitted as one object so the script makes a single
# `terraform output -json` call instead of six, which matters because each call
# re-reads the whole state file.
# ---------------------------------------------------------------------------

output "karpenter" {
  description = "Karpenter wiring: controller role (Pod Identity), instance profile, interruption queue."

  value = {
    controller_role_arn   = module.karpenter.controller_role_arn
    instance_profile_name = module.karpenter.instance_profile_name
    interruption_queue    = module.karpenter.interruption_queue_name
    cluster_name          = module.eks.cluster_name
    cluster_endpoint      = module.eks.cluster_endpoint

    # Karpenter's EC2NodeClass selects subnets and security groups by tag, and
    # its NodePool constrains topology.kubernetes.io/zone to these AZs. In
    # infra-a that constraint is a single zone, so Karpenter cannot rescue the
    # workload by launching elsewhere - it has nowhere to go. That is not a bug
    # in the experiment, it is the finding.
    discovery_tag = module.eks.cluster_name
    workload_azs  = var.workload_azs
  }
}

# ---------------------------------------------------------------------------
# FinOps bundle
#
# The deployed shape, in the exact form finops/cost_model.py expects. Exporting
# it from Terraform rather than retyping it into a spreadsheet is what keeps the
# cost model honest: if someone bumps an instance type, the model follows.
# ---------------------------------------------------------------------------

output "finops_inputs" {
  description = "Deployed resource shape, consumed by the FinOps cost model."

  value = {
    stack        = var.name
    cost_profile = var.cost_profile

    nat_gateway_count = module.vpc.nat_gateway_count

    node_instance_type  = var.system_node_group.instance_types[0]
    node_capacity_type  = var.system_node_group.capacity_type
    node_desired_count  = var.system_node_group.desired_size
    node_disk_gb        = var.system_node_group.disk_size
    workload_az_count   = length(var.workload_azs)
    cross_az_traffic_gb = length(var.workload_azs) > 1 ? 100 : 0

    db_instance_class   = var.db_instance_class
    db_multi_az         = var.db_multi_az
    db_storage_gb       = var.db_allocated_storage
    db_read_replica     = var.db_create_read_replica
    db_backup_retention = var.db_backup_retention_period

    eks_cluster_count = 1
  }
}
