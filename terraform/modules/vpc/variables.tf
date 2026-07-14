# ---------------------------------------------------------------------------
# module: vpc
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
#
# The AZ topology is the single biggest structural difference between the two
# infrastructures under comparison, so it is a pure input here:
#   infra-a -> azs = ["eu-west-3a"]                 single_nat_gateway = true
#   infra-b -> azs = [".. a", ".. b", ".. c"]       single_nat_gateway = false
# ---------------------------------------------------------------------------

variable "name" {
  description = "Name prefix for every resource in this VPC."
  type        = string
}

variable "cidr" {
  description = "IPv4 CIDR block for the VPC. A /16 leaves room for Karpenter to scale pod ENIs."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.cidr))
    error_message = "cidr must be a valid IPv4 CIDR block, e.g. 10.0.0.0/16."
  }
}

variable "azs" {
  description = <<-EOT
    Availability Zones to carve subnets in.

    Note this is the *subnet footprint*, not where the workload runs. AWS refuses
    to create an EKS control plane, or an RDS subnet group, with subnets in fewer
    than two AZs - so a literally single-AZ VPC does not exist as a buildable
    thing. infra-a therefore lays down subnets in two AZs and then pins all of its
    compute and data into one of them (see the platform module's workload_azs).

    Saying "single-AZ" and quietly deploying across two would be the easy lie
    here; the honest version is that the SPOF is in placement, not in topology.
  EOT

  type = list(string)

  validation {
    condition     = length(var.azs) >= 2 && length(var.azs) <= 3
    error_message = "azs must contain 2 or 3 AZs: EKS and RDS both refuse a subnet footprint smaller than two AZs."
  }
}

variable "single_nat_gateway" {
  description = "Route every private subnet through one NAT Gateway. Saves ~32 USD/month per AZ dropped, but the NAT itself becomes an AZ-scoped SPOF."
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "Ship VPC Flow Logs to CloudWatch. Needed to prove, after a chaos run, that traffic really stopped crossing the injected AZ boundary."
  type        = bool
  default     = true
}

variable "flow_logs_retention_days" {
  description = "CloudWatch retention for flow logs. Chaos runs are analysed within days, not months."
  type        = number
  default     = 14
}

variable "cluster_name" {
  description = "EKS cluster name, used for the subnet discovery tags Karpenter and the AWS LB Controller rely on."
  type        = string
}

variable "tags" {
  description = "Tags merged into every resource. cost-center drives the FinOps split between infra-a and infra-b."
  type        = map(string)
  default     = {}
}
