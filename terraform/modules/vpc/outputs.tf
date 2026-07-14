# ---------------------------------------------------------------------------
# module: vpc / outputs
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
# ---------------------------------------------------------------------------

output "vpc_id" {
  description = "VPC id."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR, reused by the RDS security group to scope ingress."
  value       = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet ids, in the same order as var.azs. EKS nodes and RDS live here."
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet ids, in the same order as var.azs."
  value       = aws_subnet.public[*].id
}

output "azs" {
  description = "AZs actually used, echoed back so the chaos layer targets exactly what was deployed."
  value       = var.azs
}

output "subnet_ids_by_az" {
  description = "Private subnet id keyed by AZ. FIS disrupts connectivity per subnet, so it needs this mapping to blast a specific AZ."
  value       = zipmap(var.azs, aws_subnet.private[*].id)
}

output "subnet_arns_by_az" {
  description = "Private subnet ARN keyed by AZ. FIS target selectors take ARNs, not ids, so this is the form the chaos module actually consumes."
  value       = zipmap(var.azs, aws_subnet.private[*].arn)
}

output "nat_gateway_ids" {
  description = "NAT Gateway ids. Length is 1 for infra-a and len(azs) for infra-b - the cheapest observable proof of which topology is deployed."
  value       = aws_nat_gateway.this[*].id
}

output "nat_gateway_count" {
  description = "How many NAT Gateways exist. Fed straight into the FinOps model."
  value       = local.nat_count
}
