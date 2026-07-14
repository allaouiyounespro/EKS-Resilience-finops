# ---------------------------------------------------------------------------
# module: rds
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
#
# This module is where RPO is actually decided, and the decision is one boolean:
#
#   multi_az = false (infra-a)
#     One writer in one AZ. Losing the AZ means restoring from the most recent
#     backup. RDS ships transaction logs to S3 roughly every 5 minutes, so the
#     floor on RPO is "up to 5 minutes of committed transactions, gone", and RTO
#     is however long a point-in-time restore takes (tens of minutes).
#
#   multi_az = true (infra-b)
#     Synchronous physical replication to a standby in another AZ. A commit is
#     not acknowledged until it is durable on both. RPO = 0. RDS fails over on
#     its own in 60-120s, which becomes the dominant term in infra-b's RTO.
#
# The FinOps counterpart: Multi-AZ is exactly 2x the instance and storage bill.
# ---------------------------------------------------------------------------

variable "name" {
  description = "Identifier prefix for the instance and its satellites."
  type        = string
}

variable "vpc_id" {
  description = "VPC to place the security group in."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the DB subnet group. AWS demands at least two even for a single-AZ instance, so infra-a passes two subnets and simply never uses the second."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "RDS requires a subnet group spanning at least two AZs, even when multi_az is false."
  }
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to open a Postgres connection. In practice: the EKS cluster security group."
  type        = list(string)
  default     = []
}

variable "engine_version" {
  description = <<-EOT
    PostgreSQL major.minor version.

    Verify the minor still exists before pinning it - AWS *removes* old minors
    from the orderable list, and a version that was valid six months ago is not
    a version you can create today. `terraform validate` cannot see this; the
    apply fails ~20 minutes in, after the EKS cluster is already built and
    billing.

      aws rds describe-orderable-db-instance-options --engine postgres \
        --db-instance-class db.t4g.small --region eu-west-3 \
        --query 'OrderableDBInstanceOptions[?starts_with(EngineVersion, `16.`)].EngineVersion'

    16.4 was the original pin here and is already gone.
  EOT

  type    = string
  default = "16.14"
}

variable "instance_class" {
  description = "DB instance class. Identical in both infras so the cost delta isolates Multi-AZ rather than confounding it with a bigger box."
  type        = string
  default     = "db.t4g.small"
}

variable "allocated_storage" {
  description = "Initial gp3 storage in GiB."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Ceiling for storage autoscaling. Set equal to allocated_storage to disable it."
  type        = number
  default     = 200
}

variable "multi_az" {
  description = "Synchronous standby in a second AZ. This single flag is the difference between RPO=0 and RPO<=5min - and doubles the instance bill."
  type        = bool
  default     = false
}

variable "availability_zone" {
  description = <<-EOT
    Pin a single-AZ instance into a specific AZ. Null lets RDS choose.

    This is what makes infra-a's SPOF real rather than theoretical: the DB subnet
    group has to span two AZs because AWS insists, but the instance itself is
    nailed into the same AZ as the nodes and the NAT Gateway. Without this pin,
    RDS could land the writer in the surviving AZ by luck and the experiment
    would measure a database that was never in the blast radius.

    Must be null when multi_az is true - the API rejects setting both.
  EOT

  type    = string
  default = null
}

variable "backup_retention_period" {
  description = "Days of automated backups. Must be >= 1 for point-in-time recovery to exist at all, which is infra-a's only recovery path."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_period >= 1
    error_message = "backup_retention_period must be at least 1: with 0 there is no PITR, and infra-a would have no recovery story to measure."
  }
}

variable "create_read_replica" {
  description = "Provision an async read replica in another AZ. Not needed for RPO (the Multi-AZ standby covers that) - it is the manual-promotion escape hatch for a region-level event, and the read-scaling story."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Block accidental deletion. Left off in this portfolio so the whole stack can be torn down after a run; a production DB would have it on."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. True here because these databases are disposable test fixtures."
  type        = bool
  default     = true
}

variable "performance_insights_enabled" {
  description = "Performance Insights. The free tier is 7 days of retention, which is plenty to look back at what the database was doing while the AZ was on fire."
  type        = bool
  default     = true
}

variable "monitoring_interval" {
  description = "Enhanced Monitoring granularity in seconds. 0 disables it. 60s is chosen over the finer settings because per-second metrics cost real money and a 60s window still resolves a 90s failover."
  type        = number
  default     = 60

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.monitoring_interval)
    error_message = "monitoring_interval must be one of 0, 1, 5, 10, 15, 30, 60."
  }
}

variable "database_name" {
  description = "Initial database created on the instance."
  type        = string
  default     = "resilience"
}

variable "master_username" {
  description = "Master username. The password is generated by RDS and stored in Secrets Manager - it never touches Terraform state."
  type        = string
  default     = "app"
}

variable "apply_immediately" {
  description = "Apply modifications now instead of at the next maintenance window."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags merged into every resource."
  type        = map(string)
  default     = {}
}
