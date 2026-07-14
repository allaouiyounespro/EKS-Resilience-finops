# ---------------------------------------------------------------------------
# module: karpenter
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
#
# Scope: the AWS-side prerequisites only - IAM roles, the instance profile, and
# the interruption queue. The Helm release and the NodePool/EC2NodeClass CRs are
# applied out of band (see k8s/karpenter/ and scripts/bootstrap-cluster.sh).
#
# That split is deliberate. Wiring the helm/kubernetes providers into this root
# module would make every `terraform plan` depend on the cluster's API server
# being reachable - which is precisely the thing the chaos experiment takes away.
# A plan that fails because the AZ under test is down is a plan that cannot be
# used to fix it.
# ---------------------------------------------------------------------------

variable "cluster_name" {
  description = "EKS cluster Karpenter provisions nodes for."
  type        = string
}

variable "node_role_name" {
  description = "IAM role Karpenter-launched nodes assume. Reusing the managed node group's role keeps a single node identity to audit."
  type        = string
}

variable "namespace" {
  description = "Namespace the Karpenter controller runs in."
  type        = string
  default     = "kube-system"
}

variable "service_account" {
  description = "Service account name for the controller. Bound to the IAM role by the Pod Identity association - Terraform owns the binding, so a rename here updates both sides together."
  type        = string
  default     = "karpenter"
}

variable "tags" {
  description = "Tags merged into every resource."
  type        = map(string)
  default     = {}
}
