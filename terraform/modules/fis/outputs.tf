# ---------------------------------------------------------------------------
# module: fis / outputs
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
# ---------------------------------------------------------------------------

output "experiment_template_id" {
  description = "Template id. scripts/run-experiment.sh passes this straight to `aws fis start-experiment`."
  value       = aws_fis_experiment_template.az_failure.id
}

# The AWS provider does not export an ARN for this resource type, so it is
# assembled from the id. Kept as an output anyway because IAM policies that
# restrict who may start this experiment need the ARN, not the bare id.
output "experiment_template_arn" {
  description = "Template ARN, composed from the template id."
  value       = "arn:${local.partition}:fis:${local.region}:${local.account_id}:experiment-template/${aws_fis_experiment_template.az_failure.id}"
}

output "role_arn" {
  description = "Execution role FIS assumes."
  value       = aws_iam_role.fis.arn
}

output "log_group_name" {
  description = "Log group holding the per-action start/stop records the RTO clock is anchored to."
  value       = aws_cloudwatch_log_group.fis.name
}

output "target_az" {
  description = "AZ this template takes out, echoed back for the run report."
  value       = var.target_az
}

output "rds_failover_enabled" {
  description = "Whether the RDS failover action is part of the template. False for infra-a, which has no standby to fail over to."
  value       = var.enable_rds_failover
}
