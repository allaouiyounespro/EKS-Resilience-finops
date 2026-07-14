# ---------------------------------------------------------------------------
# stack: infra-b / inputs
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
#
# Deliberately the same variable set as infra-a, with the same defaults for
# everything that is not a resilience decision. If these two files ever drift on
# region, instance class or chaos duration, the RTO/cost comparison stops being
# a controlled experiment and becomes an anecdote.
# ---------------------------------------------------------------------------

variable "name" {
  description = "Stack name, used as the EKS cluster name and as a prefix everywhere else."
  type        = string
  default     = "resilience-b"
}

variable "region" {
  description = "AWS region. Must match infra-a."
  type        = string
  default     = "eu-west-3"
}

variable "vpc_cidr" {
  description = "VPC CIDR. Disjoint from infra-a's so both stacks can live in one account simultaneously."
  type        = string
  default     = "10.20.0.0/16"
}

variable "azs" {
  description = "Subnet footprint. Three AZs, and unlike infra-a, the workload is allowed into all of them."
  type        = list(string)
  default     = ["eu-west-3a", "eu-west-3b", "eu-west-3c"]
}

variable "kubernetes_version" {
  description = "EKS control plane version. Must match infra-a."
  type        = string
  default     = "1.34"
}

variable "system_node_group" {
  description = <<-EOT
    System node group shape.

    desired_size is 3, one per AZ. This is the single most important difference
    that nobody puts on the invoice: it means the Karpenter controller itself
    survives the AZ that gets destroyed.

    If Karpenter dies in the same blast as the workload, there is nothing left to
    provision replacement capacity, and the measured RTO is not "90 seconds", it
    is "however long until a human notices". The third node costs ~30 USD/month
    and is what turns automated recovery from a claim into a fact.
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
    min_size       = 3
    max_size       = 6
    desired_size   = 3
    disk_size      = 30
  }
}

variable "db_instance_class" {
  description = "RDS instance class. Same in both stacks - the cost delta must isolate Multi-AZ, not instance size."
  type        = string
  default     = "db.t4g.small"
}

variable "db_allocated_storage" {
  description = "RDS storage in GiB. Same in both stacks."
  type        = number
  default     = 20
}

variable "chaos_duration_minutes" {
  description = "How long FIS holds the AZ down. Same in both stacks, or the RTO numbers are not comparable."
  type        = number
  default     = 15
}

variable "cluster_admin_arns" {
  description = "IAM principals granted cluster-admin."
  type        = list(string)
  default     = []
}

variable "cluster_public_access_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  description = "Extra tags merged into every resource."
  type        = map(string)
  default     = {}
}
