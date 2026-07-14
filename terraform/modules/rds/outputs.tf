# ---------------------------------------------------------------------------
# module: rds / outputs
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
# ---------------------------------------------------------------------------

output "db_instance_id" {
  description = "Instance identifier. FIS targets this to force a failover."
  value       = aws_db_instance.this.identifier
}

output "db_instance_arn" {
  description = "Instance ARN, needed by the FIS target selector."
  value       = aws_db_instance.this.arn
}

output "endpoint" {
  description = "Writer endpoint, host:port. On a Multi-AZ failover the DNS record behind this flips to the standby - the app keeps the same connection string."
  value       = aws_db_instance.this.endpoint
}

output "address" {
  description = "Writer hostname without the port."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "Postgres port."
  value       = aws_db_instance.this.port
}

output "database_name" {
  description = "Initial database name."
  value       = aws_db_instance.this.db_name
}

output "availability_zone" {
  description = "AZ the writer currently sits in. Captured before a chaos run so the report can assert the failover actually moved it."
  value       = aws_db_instance.this.availability_zone
}

output "multi_az" {
  description = "Whether a synchronous standby exists. Drives the expected-RPO column in the results table."
  value       = aws_db_instance.this.multi_az
}

output "master_user_secret_arn" {
  description = "Secrets Manager ARN holding the RDS-managed master credentials. The app and the RPO probe both resolve the password from here."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "security_group_id" {
  description = "Security group in front of the database."
  value       = aws_security_group.this.id
}

output "replica_endpoint" {
  description = "Read replica endpoint, or null when no replica was created."
  value       = var.create_read_replica ? aws_db_instance.replica[0].endpoint : null
}
