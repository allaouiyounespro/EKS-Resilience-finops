# ---------------------------------------------------------------------------
# module: karpenter / outputs
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
#
# These feed the Helm values and the EC2NodeClass rendered by
# scripts/bootstrap-cluster.sh.
# ---------------------------------------------------------------------------

output "controller_role_arn" {
  description = "Controller role, bound to the karpenter service account by a Pod Identity association. Nothing in the Helm values references it anymore - it is exported for auditing."
  value       = aws_iam_role.controller.arn
}

output "instance_profile_name" {
  description = "Instance profile attached to Karpenter-launched nodes. Referenced by spec.instanceProfile in the EC2NodeClass."
  value       = aws_iam_instance_profile.node.name
}

output "interruption_queue_name" {
  description = "SQS queue name for interruption events. Goes into settings.interruptionQueue in the Helm values."
  value       = aws_sqs_queue.interruption.name
}

output "interruption_queue_arn" {
  description = "SQS queue ARN."
  value       = aws_sqs_queue.interruption.arn
}

output "node_role_name" {
  description = "Node role echoed back, so the bootstrap script has a single source for it."
  value       = var.node_role_name
}
