# ---------------------------------------------------------------------------
# module: rds
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
# ---------------------------------------------------------------------------

locals {
  tags = merge(
    var.tags,
    {
      Module = "rds"
      Owner  = "allaouiyounespro"
    },
  )

  # Family is derived from the major version so that bumping engine_version from
  # 16.4 to 16.6 does not silently point at the wrong parameter group family.
  major_version     = split(".", var.engine_version)[0]
  parameter_family  = "postgres${local.major_version}"
  monitoring_needed = var.monitoring_interval > 0
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids

  tags = merge(local.tags, { Name = var.name })
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

resource "aws_security_group" "this" {
  name        = "${var.name}-rds"
  description = "Postgres ingress for ${var.name}"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${var.name}-rds" })

  lifecycle {
    create_before_destroy = true
  }
}

# Source-group based rather than CIDR based: pods get addresses from the whole
# VPC range via the CNI, so a CIDR rule here would be indistinguishable from
# "allow the entire VPC" and would survive any future subnet added to the VPC.
resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = toset(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "Postgres from ${each.value}"

  tags = local.tags
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Allow all egress"

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Engine configuration
# ---------------------------------------------------------------------------

resource "aws_db_parameter_group" "this" {
  name        = "${var.name}-pg${local.major_version}"
  family      = local.parameter_family
  description = "Postgres tuning for ${var.name}"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  # Every statement slower than 500ms lands in the Postgres log. After a
  # failover this is what distinguishes "the database was slow" from "the
  # database was gone", which are two very different RTO stories.
  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Enhanced monitoring role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "monitoring_assume" {
  count = local.monitoring_needed ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "monitoring" {
  count = local.monitoring_needed ? 1 : 0

  name               = "${var.name}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.monitoring_assume[0].json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  count = local.monitoring_needed ? 1 : 0

  role       = aws_iam_role.monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ---------------------------------------------------------------------------
# Primary instance
# ---------------------------------------------------------------------------

resource "aws_db_instance" "this" {
  identifier = var.name

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  # gp3 rather than gp2: same price per GiB, but the baseline IOPS do not scale
  # with volume size, so a 50 GiB volume is not artificially throttled while the
  # RPO probe hammers it with small writes.
  storage_type          = "gp3"
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_encrypted     = true

  db_name  = var.database_name
  username = var.master_username

  # RDS generates and rotates the password into Secrets Manager. Nothing sensitive
  # ends up in the Terraform state file, and the app resolves the secret at runtime.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  parameter_group_name   = aws_db_parameter_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  port                   = 5432
  publicly_accessible    = false

  # The flag the whole comparison hinges on.
  multi_az = var.multi_az

  # Only meaningful for a single-AZ instance; a Multi-AZ instance places its own
  # writer and standby, and the API rejects an explicit AZ alongside it. The
  # precondition below turns that into a plan-time error rather than a surprise
  # halfway through an apply.
  availability_zone = var.availability_zone

  backup_retention_period = var.backup_retention_period
  backup_window           = "02:00-03:00"
  maintenance_window      = "sun:03:30-sun:04:30"
  copy_tags_to_snapshot   = true

  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_enabled ? 7 : null
  monitoring_interval                   = var.monitoring_interval
  monitoring_role_arn                   = local.monitoring_needed ? aws_iam_role.monitoring[0].arn : null

  # postgresql = the query/error log; upgrade = what happened during a version bump.
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  auto_minor_version_upgrade = true
  deletion_protection        = var.deletion_protection
  skip_final_snapshot        = var.skip_final_snapshot
  final_snapshot_identifier  = var.skip_final_snapshot ? null : "${var.name}-final"
  apply_immediately          = var.apply_immediately

  # Pin the CA explicitly. The witness connects with sslmode=require, and when
  # AWS rotates the default CA (as it did with rds-ca-2019), instances on the
  # old cert get a forced restart in a maintenance window nobody chose. Pinning
  # makes the rotation a deliberate, diffable change instead of a surprise.
  ca_cert_identifier = "rds-ca-rsa2048-g1"

  tags = merge(local.tags, { Name = var.name })

  lifecycle {
    # RDS rotates the secret and bumps the minor version on its own; neither
    # should show up as drift on the next plan.
    ignore_changes = [master_user_secret_kms_key_id, engine_version]

    precondition {
      condition     = !(var.multi_az && var.availability_zone != null)
      error_message = "availability_zone cannot be set when multi_az is true: RDS chooses the writer and standby placement itself."
    }
  }
}

# ---------------------------------------------------------------------------
# Read replica (infra-b only)
#
# Asynchronous, so it contributes nothing to RPO - the synchronous Multi-AZ
# standby already covers that. It exists as the manual promotion path for a
# failure that outlives a single AZ, and to take read load off the writer.
# ---------------------------------------------------------------------------

resource "aws_db_instance" "replica" {
  count = var.create_read_replica ? 1 : 0

  identifier          = "${var.name}-replica"
  replicate_source_db = aws_db_instance.this.identifier
  instance_class      = var.instance_class

  # A replica inherits storage and engine from its source; setting them here is
  # rejected by the API. Only the placement and observability knobs are ours.
  multi_az            = false
  publicly_accessible = false
  skip_final_snapshot = true

  vpc_security_group_ids = [aws_security_group.this.id]

  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_enabled ? 7 : null
  monitoring_interval                   = var.monitoring_interval
  monitoring_role_arn                   = local.monitoring_needed ? aws_iam_role.monitoring[0].arn : null

  auto_minor_version_upgrade = true
  deletion_protection        = var.deletion_protection

  tags = merge(local.tags, { Name = "${var.name}-replica", Role = "read-replica" })

  lifecycle {
    ignore_changes = [engine_version]
  }
}
