# ---------------------------------------------------------------------------
# module: eks / outputs
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
# ---------------------------------------------------------------------------

output "cluster_name" {
  description = "Cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA bundle for the API server."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  description = "Control plane version actually running."
  value       = aws_eks_cluster.this.version
}

output "cluster_security_group_id" {
  description = "Security group EKS created for the cluster. RDS grants ingress to it so pods can reach Postgres without a hand-rolled SG."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_role_arn" {
  description = "IAM role the system node group runs as. Karpenter reuses it for the nodes it launches, so there is one role to audit instead of two."
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  description = "Name of the node IAM role, needed to build the Karpenter instance profile."
  value       = aws_iam_role.node.name
}

output "secrets_kms_key_arn" {
  description = "KMS key wrapping Kubernetes Secrets in etcd."
  value       = aws_kms_key.secrets.arn
}
