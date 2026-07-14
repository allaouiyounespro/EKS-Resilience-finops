# ---------------------------------------------------------------------------
# stack: infra-a / outputs
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
#
# Identical to infra-b's, on purpose: every downstream script (bootstrap, chaos
# runner, RPO probe, cost model) reads the same output names regardless of which
# stack it is pointed at. One tool, two targets, no special-casing.
# ---------------------------------------------------------------------------

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.platform.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = module.platform.cluster_endpoint
}

output "region" {
  description = "Region the stack lives in."
  value       = var.region
}

output "workload_azs" {
  description = "AZs the workload actually runs in. One entry: this is the single-AZ stack."
  value       = module.platform.workload_azs
}

output "db_endpoint" {
  description = "Postgres writer endpoint."
  value       = module.platform.db_endpoint
}

output "db_secret_arn" {
  description = "Secrets Manager ARN for the database credentials."
  value       = module.platform.db_secret_arn
}

output "db_multi_az" {
  description = "False here. There is no standby, so recovery is a restore."
  value       = module.platform.db_multi_az
}

output "fis_experiment_template_id" {
  description = "FIS template id for the AZ failure experiment."
  value       = module.platform.fis_experiment_template_id
}

output "fis_target_az" {
  description = "The AZ the experiment destroys."
  value       = module.platform.fis_target_az
}

output "karpenter" {
  description = "Karpenter wiring for scripts/bootstrap-cluster.sh."
  value       = module.platform.karpenter
}

output "finops_inputs" {
  description = "Deployed shape, consumed by finops/cost_model.py."
  value       = module.platform.finops_inputs
}
