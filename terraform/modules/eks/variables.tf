# ---------------------------------------------------------------------------
# module: eks
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
#
# The managed node group here is deliberately small: it only carries the
# "system" workloads that must exist before Karpenter can do anything
# (Karpenter itself, CoreDNS, kube-prometheus-stack). Every application pod is
# scheduled onto nodes that Karpenter provisions, which is what makes the
# post-chaos recovery time an actual measurement of Karpenter's behaviour
# rather than of a pre-warmed ASG.
# ---------------------------------------------------------------------------

variable "name" {
  description = "Cluster name. Also the value Karpenter and the subnet discovery tags key off."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS control plane minor version. 1.34 is current at time of writing; bump deliberately, and bump both stacks together or the comparison stops being controlled."
  type        = string
  default     = "1.34"
}

variable "vpc_id" {
  description = "VPC the cluster lives in."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet ids for the control plane ENIs. AWS requires at least two AZs here regardless of where the workload runs."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "EKS requires control plane subnets in at least two AZs."
  }
}

variable "node_subnet_ids" {
  description = <<-EOT
    Subnets the system node group may launch into. Kept separate from subnet_ids
    because they answer different questions: subnet_ids is "where may the
    AWS-managed control plane put its ENIs" (two AZs, non-negotiable), while this
    is "where is my capacity allowed to exist" (one AZ for infra-a).

    Collapsing the two would silently spread infra-a's nodes across both AZs and
    the single-AZ architecture under test would quietly stop being single-AZ.
  EOT

  type = list(string)
}

variable "endpoint_public_access" {
  description = "Expose the API server publicly. True in this portfolio so the chaos runner can drive the cluster from a laptop; a production cluster would pin this to false plus a VPN."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. Defaults to the world, which is exactly what you should not ship - override it."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "system_node_group" {
  description = <<-EOT
    System node group shape. desired_size is intentionally >= 2 in infra-b so
    that losing one AZ does not take the Karpenter controller with it - if
    Karpenter dies in the same blast as the workload, nothing is left to
    replace the workload and the measured RTO becomes "infinite".
  EOT

  type = object({
    instance_types = list(string)
    capacity_type  = string
    min_size       = number
    max_size       = number
    desired_size   = number
    disk_size      = number
  })

  default = {
    instance_types = ["t3.medium"]
    capacity_type  = "ON_DEMAND"
    min_size       = 1
    max_size       = 4
    desired_size   = 2
    disk_size      = 30
  }

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.system_node_group.capacity_type)
    error_message = "capacity_type must be ON_DEMAND or SPOT."
  }

  validation {
    condition     = var.system_node_group.desired_size >= var.system_node_group.min_size && var.system_node_group.desired_size <= var.system_node_group.max_size
    error_message = "desired_size must sit between min_size and max_size."
  }
}

variable "enabled_log_types" {
  description = "Control plane logs shipped to CloudWatch. The audit log is what tells you, after the fact, exactly when the kubelets in the dead AZ stopped heartbeating."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "log_retention_days" {
  description = "Retention for the control plane log group."
  type        = number
  default     = 14
}

variable "cluster_admin_arns" {
  description = "IAM principals granted cluster-admin through EKS access entries. Empty means only the creating principal can reach the API."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags merged into every resource."
  type        = map(string)
  default     = {}
}
