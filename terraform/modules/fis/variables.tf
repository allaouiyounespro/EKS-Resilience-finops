# ---------------------------------------------------------------------------
# module: fis
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
#
# One experiment template, instantiated identically against both infrastructures.
# That symmetry is the whole methodology: if the fault differs between infra-a
# and infra-b, the RTO comparison measures the fault, not the architecture.
#
# The AZ failure is injected as three simultaneous actions, because a real AZ
# event is not one clean thing:
#
#   1. network disruption   - the subnets in the target AZ stop talking to
#                             anything outside themselves. This is what kills the
#                             shared NAT Gateway in infra-a.
#   2. instance stop        - the EKS nodes in that AZ go away hard, with no
#                             graceful drain. This is what Karpenter must react to.
#   3. RDS forced failover  - the writer is pushed to its standby, if it has one.
#                             In infra-a there is no standby, so this action is
#                             simply not attached, and the database stays down.
# ---------------------------------------------------------------------------

variable "name" {
  description = "Experiment template name prefix."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster whose nodes are in scope. Used to build the instance tag filter."
  type        = string
}

variable "target_az" {
  description = "The AZ to take out. Must be one of the AZs the stack was deployed into - for infra-a that is the only AZ, which is the point."
  type        = string
}

variable "target_subnet_arns" {
  description = "ARNs of the subnets in target_az to cut off. Comes from the vpc module's subnet_arns_by_az output."
  type        = list(string)

  validation {
    condition     = length(var.target_subnet_arns) > 0
    error_message = "target_subnet_arns cannot be empty: an experiment with no targets would report success while doing nothing."
  }
}

variable "db_instance_arn" {
  description = "RDS instance to force a failover on."
  type        = string
}

variable "enable_rds_failover" {
  description = <<-EOT
    Attach the RDS failover action. Only meaningful when the instance is Multi-AZ:
    a forced reboot of a single-AZ instance is just a reboot, and it would add an
    artificial outage to infra-a that a real AZ failure would not have caused in
    that exact form. Left false for infra-a so its numbers stay defensible.
  EOT

  type    = bool
  default = false
}

variable "duration_minutes" {
  description = "How long the network stays disrupted. 15 minutes is long enough for Karpenter to provision replacement capacity in another AZ and for the system to settle, so the measured RTO is a real recovery and not a transient dip."
  type        = number
  default     = 15

  validation {
    condition     = var.duration_minutes >= 1 && var.duration_minutes <= 60
    error_message = "duration_minutes must be between 1 and 60."
  }
}

variable "stop_condition_alarm_arns" {
  description = <<-EOT
    CloudWatch alarms that abort the experiment early. This is the seatbelt: if
    blast radius escapes what was predicted, FIS rolls the fault back on its own
    instead of waiting for a human to notice. Empty means the experiment runs to
    completion no matter what happens, which is only acceptable in a throwaway
    account.
  EOT

  type    = list(string)
  default = []
}

variable "log_retention_days" {
  description = "Retention for the FIS experiment log group. These logs are the authoritative record of when each action started and stopped, so they are what the RTO clock is anchored to."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags merged into every resource."
  type        = map(string)
  default     = {}
}
