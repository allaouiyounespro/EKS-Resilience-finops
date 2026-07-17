# ---------------------------------------------------------------------------
# module: platform
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
#
# Composes vpc + eks + rds + karpenter + fis into one deployable unit.
#
# Why this layer exists: infra-a and infra-b must be the *same* platform with
# different resilience settings. If they were two hand-written root modules,
# they would drift - someone would bump an instance type in one and not the
# other - and the cost comparison would quietly stop being apples-to-apples.
#
# Here, the entire difference between the 180 USD/month architecture and the
# 380 USD/month one is a diff between two tfvars files. That diff is the
# deliverable.
# ---------------------------------------------------------------------------

variable "name" {
  description = "Stack name. Prefixes every resource and names the EKS cluster."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR. The two stacks use different ranges so they can coexist in one account and even be peered for a side-by-side run."
  type        = string
}

variable "azs" {
  description = <<-EOT
    Subnet footprint. Two AZs minimum, because EKS and RDS both refuse anything
    smaller. This is NOT a statement about where the workload runs - see
    workload_azs.
  EOT

  type = list(string)

  validation {
    condition     = length(var.azs) >= 2 && length(var.azs) <= 3
    error_message = "azs must contain 2 or 3 AZs."
  }
}

variable "workload_azs" {
  description = <<-EOT
    The AZs compute and data are actually allowed to run in. Must be a subset of
    azs.

      infra-a -> one entry. Nodes, NAT and the RDS writer all land in that AZ.
                 The second AZ exists only to satisfy AWS's subnet-group rules
                 and carries nothing. Killing the one AZ kills the application.

      infra-b -> all three. Nodes spread, NAT per AZ, RDS standby elsewhere.

    Keeping this separate from azs is what stops "single-AZ" from being a lie:
    the topology is forced to span two AZs, so the SPOF has to be expressed as a
    placement constraint instead.
  EOT

  type = list(string)

  validation {
    condition     = length(var.workload_azs) >= 1
    error_message = "workload_azs needs at least one AZ."
  }

  validation {
    condition     = length(setsubtract(var.workload_azs, var.azs)) == 0
    error_message = "workload_azs must be a subset of azs: you cannot place a node in an AZ that has no subnet."
  }
}

variable "single_nat_gateway" {
  description = "Share one NAT Gateway across all private subnets. True for infra-a."
  type        = bool
}

variable "kubernetes_version" {
  description = "EKS control plane version. Pinned identically across both stacks - a version skew would confound the comparison."
  type        = string
  default     = "1.34"
}

variable "system_node_group" {
  description = "Shape of the managed node group carrying Karpenter, CoreDNS and the monitoring stack."

  type = object({
    instance_types = list(string)
    capacity_type  = string
    min_size       = number
    max_size       = number
    desired_size   = number
    disk_size      = number
  })
}

variable "db_instance_class" {
  description = "RDS instance class. Identical in both stacks by design: the cost delta must isolate Multi-AZ, not instance size."
  type        = string
  default     = "db.t4g.small"
}

variable "db_allocated_storage" {
  description = "RDS gp3 storage in GiB."
  type        = number
  default     = 20
}

variable "db_multi_az" {
  description = "Synchronous standby in a second AZ. The RPO=0 switch. False for infra-a."
  type        = bool
}

variable "db_create_read_replica" {
  description = "Async read replica. The DR promotion path. True for infra-b only."
  type        = bool
  default     = false
}

variable "db_backup_retention_period" {
  description = "Days of automated backups. infra-a keeps the minimum that still allows PITR, since PITR is its only recovery path; infra-b keeps a week."
  type        = number
  default     = 7
}

variable "chaos_target_az" {
  description = <<-EOT
    AZ the FIS experiment takes out, for a SINGLE-AZ stack.

    Ignored when db_multi_az is true: a Multi-AZ instance's placement cannot be
    pinned (the API rejects an explicit AZ alongside multi_az), so RDS chooses,
    and the experiment targets whatever it chose. Aiming anywhere else means the
    fault misses the database and the failover never fires - a run that completes,
    reports a number, and measures nothing.
  EOT

  type = string

  validation {
    condition     = contains(var.workload_azs, var.chaos_target_az)
    error_message = "chaos_target_az must be one of workload_azs: an experiment aimed at an AZ with no workload in it resolves zero targets and proves nothing."
  }
}

variable "chaos_duration_minutes" {
  description = "How long the fault is held. Identical across both stacks."
  type        = number
  default     = 15
}

variable "cluster_admin_arns" {
  description = "IAM principals granted cluster-admin via EKS access entries."
  type        = list(string)
  default     = []
}

variable "cluster_public_access_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cost_profile" {
  description = "Free-form label carried into the cost-allocation tags, so Cost Explorer can split the bill between the two architectures without guessing."
  type        = string
}

variable "tags" {
  description = "Extra tags merged into everything the stack creates."
  type        = map(string)
  default     = {}
}
