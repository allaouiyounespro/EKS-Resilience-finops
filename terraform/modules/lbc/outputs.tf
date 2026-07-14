# ---------------------------------------------------------------------------
# module: lbc / outputs
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
# ---------------------------------------------------------------------------

output "controller_role_arn" {
  description = "Controller role, bound via Pod Identity. Exported for auditing; the Helm values never reference it."
  value       = aws_iam_role.controller.arn
}

output "service_account" {
  description = "Service account name the association binds. The Helm release must create exactly this name or the controller runs with the node role instead - and the node role can describe load balancers but never create one."
  value       = var.service_account
}
