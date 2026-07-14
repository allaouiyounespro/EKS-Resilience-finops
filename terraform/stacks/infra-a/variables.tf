# ---------------------------------------------------------------------------
# stack: infra-a / inputs
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
#
# Identical to infra-b's. Every knob that could confound the comparison - region,
# instance sizes, Kubernetes version, chaos duration - is declared in both stacks
# with the same defaults, so the only things that differ are the resilience
# decisions hard-coded in main.tf.
# ---------------------------------------------------------------------------

variable "name" {
  description = "Stack name, used as the EKS cluster name and as a prefix everywhere else."
  type        = string
  default     = "resilience-a"
}

variable "region" {
  description = "AWS region. eu-west-3 (Paris) by default: three AZs, EU data residency, and cheaper than eu-west-1 for NAT."
  type        = string
  default     = "eu-west-3"
}

variable "vpc_cidr" {
  description = "VPC CIDR. Disjoint from infra-b's so both stacks can live in one account simultaneously."
  type        = string
  default     = "10.10.0.0/16"
}

variable "azs" {
  description = "Subnet footprint. Two AZs is the AWS-mandated minimum; infra-a only ever uses the first."
  type        = list(string)
  default     = ["eu-west-3a", "eu-west-3b"]
}

variable "kubernetes_version" {
  description = "EKS control plane version. Must match infra-b."
  type        = string
  default     = "1.34"
}

variable "system_node_group" {
  description = <<-EOT
    System node group shape.

    desired_size is 2 here rather than 3. That is not penny-pinching for its own
    sake - it is what a single-AZ design actually implies: there is no third AZ
    to put a third node in, so spreading the system tier buys nothing. Both nodes
    sit in the same AZ and die together.
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
    min_size       = 2
    max_size       = 5
    desired_size   = 2
    disk_size      = 30
  }
}

variable "db_instance_class" {
  description = "RDS instance class. Same in both stacks."
  type        = string
  default     = "db.t4g.medium"
}

variable "db_allocated_storage" {
  description = "RDS storage in GiB. Same in both stacks."
  type        = number
  default     = 50
}

variable "chaos_duration_minutes" {
  description = "How long FIS holds the AZ down. Same in both stacks, or the RTO numbers are not comparable."
  type        = number
  default     = 15
}

variable "cluster_admin_arns" {
  description = "IAM principals granted cluster-admin. Add your own role ARN here or you will not be able to reach the API from CI."
  type        = list(string)
  default     = []
}

variable "cluster_public_access_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API. Narrow this to your egress IP before leaving a cluster running overnight."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  description = "Extra tags merged into every resource."
  type        = map(string)
  default     = {}
}
