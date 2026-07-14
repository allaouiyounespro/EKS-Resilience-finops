# ---------------------------------------------------------------------------
# module: fis
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
# ---------------------------------------------------------------------------

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  tags = merge(
    var.tags,
    {
      Module = "fis"
      Owner  = "allaouiyounespro"
    },
  )

  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  template_name = "${var.name}-az-failure"
  duration      = "PT${var.duration_minutes}M"
}

# ---------------------------------------------------------------------------
# Execution role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["fis.amazonaws.com"]
    }

    # Confused-deputy guard: without these, any FIS experiment in any account
    # that knows this role's ARN could ask AWS to assume it.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:fis:${local.region}:${local.account_id}:experiment/*"]
    }
  }
}

resource "aws_iam_role" "fis" {
  name               = "${var.name}-fis"
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = local.tags
}

# AWS publishes one managed policy per fault domain. Attaching the three that
# match the three actions in the template - and nothing more - keeps the blast
# radius of a stolen FIS role bounded to what the experiment could already do.
resource "aws_iam_role_policy_attachment" "managed" {
  for_each = toset([
    "arn:${local.partition}:iam::aws:policy/service-role/AWSFaultInjectionSimulatorEC2Access",
    "arn:${local.partition}:iam::aws:policy/service-role/AWSFaultInjectionSimulatorNetworkAccess",
    "arn:${local.partition}:iam::aws:policy/service-role/AWSFaultInjectionSimulatorRDSAccess",
  ])

  role       = aws_iam_role.fis.name
  policy_arn = each.value
}

data "aws_iam_policy_document" "logging" {
  # Writing into the experiment's own log group: scoped to that group.
  statement {
    sid    = "WriteExperimentLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["${aws_cloudwatch_log_group.fis.arn}:*"]
  }

  # The log-delivery management APIs genuinely require "*" - they are
  # account-level operations with no resource to scope to, and FIS refuses to
  # start with them missing. Documented in the FIS logging guide; kept in their
  # own statement so the broad grant is visibly separate from the narrow one.
  statement {
    sid    = "ManageLogDelivery"
    effect = "Allow"

    actions = [
      "logs:CreateLogDelivery",
      "logs:DescribeLogGroups",
      "logs:DescribeResourcePolicies",
      "logs:PutResourcePolicy",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "logging" {
  name   = "${var.name}-fis-logging"
  role   = aws_iam_role.fis.id
  policy = data.aws_iam_policy_document.logging.json
}

resource "aws_cloudwatch_log_group" "fis" {
  name              = "/aws/fis/${var.name}"
  retention_in_days = var.log_retention_days

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Experiment template
# ---------------------------------------------------------------------------

resource "aws_fis_experiment_template" "az_failure" {
  description = "Simulated ${var.target_az} failure for ${var.cluster_name}: network isolation + node loss${var.enable_rds_failover ? " + RDS failover" : ""}"
  role_arn    = aws_iam_role.fis.arn

  tags = merge(local.tags, {
    Name          = local.template_name
    ChaosScenario = "az-failure"
    TargetAZ      = var.target_az
  })

  experiment_options {
    account_targeting = "single-account"

    # "fail" over "skip": if a target selector resolves to zero resources, the
    # experiment must refuse to start. The alternative is an experiment that
    # reports SUCCESS having injected nothing, and an RTO of 0 that means the
    # tooling was broken rather than the architecture being good.
    empty_target_resolution_mode = "fail"
  }

  log_configuration {
    log_schema_version = 2

    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
  }

  # A stop condition of "none" is a loaded gun. It is allowed here only because
  # this runs in a disposable account, and the caller has to opt into it by
  # passing an empty list explicitly.
  dynamic "stop_condition" {
    for_each = length(var.stop_condition_alarm_arns) == 0 ? [1] : []

    content {
      source = "none"
    }
  }

  dynamic "stop_condition" {
    for_each = toset(var.stop_condition_alarm_arns)

    content {
      source = "aws:cloudwatch:alarm"
      value  = stop_condition.value
    }
  }

  # -------------------------------------------------------------------------
  # Targets
  # -------------------------------------------------------------------------

  target {
    name           = "SubnetsInTargetAZ"
    resource_type  = "aws:ec2:subnet"
    resource_arns  = var.target_subnet_arns
    selection_mode = "ALL"
  }

  target {
    name          = "NodesInTargetAZ"
    resource_type = "aws:ec2:instance"

    # Tag-based rather than ARN-based on purpose: Karpenter creates and destroys
    # instances continuously, so a list of instance ARNs captured at plan time is
    # already stale by the time the experiment runs. The tag is applied by EKS to
    # every node that joins this cluster, including Karpenter's.
    resource_tag {
      key   = "kubernetes.io/cluster/${var.cluster_name}"
      value = "owned"
    }

    filter {
      path   = "Placement.AvailabilityZone"
      values = [var.target_az]
    }

    filter {
      path   = "State.Name"
      values = ["running"]
    }

    selection_mode = "ALL"
  }

  dynamic "target" {
    for_each = var.enable_rds_failover ? [1] : []

    content {
      name           = "WriterDatabase"
      resource_type  = "aws:rds:db"
      resource_arns  = [var.db_instance_arn]
      selection_mode = "ALL"
    }
  }

  # -------------------------------------------------------------------------
  # Actions
  #
  # All three start at t=0. No startAfter chaining: an AZ does not fail in
  # stages, and staggering the actions would let the workload partially recover
  # between them and flatter the RTO.
  # -------------------------------------------------------------------------

  action {
    name        = "isolate-az-network"
    description = "Cut the target AZ's subnets off from everything outside them"
    action_id   = "aws:network:disrupt-connectivity"

    target {
      key   = "Subnets"
      value = "SubnetsInTargetAZ"
    }

    parameter {
      key   = "duration"
      value = local.duration
    }

    # scope = "all", and getting this wrong invalidated an entire campaign.
    #
    # The obvious choice is "availability-zone", which drops traffic *crossing*
    # the AZ boundary while leaving intra-AZ traffic intact. It sounds like the
    # more accurate model of a real AZ event, and for a multi-AZ workload it
    # nearly is.
    #
    # For a single-AZ workload it is catastrophically wrong, because infra-a
    # lives entirely inside the target AZ. Nothing it does crosses the boundary.
    # So the "AZ failure" left the AZ perfectly able to talk to itself: Karpenter
    # launched replacement nodes *in the dead zone*, they reached the control
    # plane, pulled images through the NAT next door, joined, and the service was
    # back in 4m48s - while FIS still had eleven minutes of "outage" left to run.
    #
    # The measured RTO was real. It just was not the RTO of an AZ failure. It was
    # the RTO of "every node was stopped once", which is a different and far less
    # interesting question - and the number would have been published under the
    # wrong name.
    #
    # "all" cuts every packet in and out of the target subnets: no control plane,
    # no NAT, no ECR. Replacement capacity cannot join, pods stay Pending, and the
    # outage lasts as long as the fault does. Which is the point.
    #
    # Known limitation, stated because it matters: FIS implements this with
    # network ACLs, and NACLs do not filter traffic *within* a subnet. A real AZ
    # loss also means EC2 refuses to launch there at all, and no FIS action can
    # simulate that. The measured RTO remains a lower bound.
    parameter {
      key   = "scope"
      value = "all"
    }
  }

  action {
    name        = "stop-nodes-in-az"
    description = "Hard-stop every EKS node in the target AZ, with no drain"
    action_id   = "aws:ec2:stop-instances"

    target {
      key   = "Instances"
      value = "NodesInTargetAZ"
    }

    # There is deliberately NO startInstancesAfterDuration here, and the reason
    # invalidated a whole campaign before it was understood.
    #
    # That parameter asks FIS to restart the exact instances it stopped, once the
    # duration elapses. In a Karpenter cluster those instances no longer exist:
    # Karpenter sees dead nodes, reclaims them, and launches replacements. When
    # FIS then tries to resurrect its own, EC2 refuses - "one or more instances
    # are in an incorrect state" - the action fails, and FIS reacts to a failed
    # action by STOPPING every other action in the experiment. Including the
    # network disruption.
    #
    # So the fault window collapsed from 15 minutes to about five, the service
    # recovered early, and the run reported a beautiful RTO of 341s. It was not
    # measuring a faster recovery. It was measuring a shorter outage. Averaged
    # with an honest run, it would have halved the headline number and nothing
    # would have looked wrong.
    #
    # Two systems each doing their job correctly, destroying the experiment
    # between them.
    #
    # Removing it is also the more honest model: a real AZ failure does not hand
    # your instances back on a timer. Capacity returns because the autoscaler
    # replaces it - which is precisely the behaviour under test, and in infra-a
    # the behaviour that cannot happen, because Karpenter has nowhere to go.
  }

  dynamic "action" {
    for_each = var.enable_rds_failover ? [1] : []

    content {
      name        = "failover-database"
      description = "Force the writer onto its standby in a surviving AZ"
      action_id   = "aws:rds:reboot-db-instances"

      target {
        key   = "DBInstances"
        value = "WriterDatabase"
      }

      # forceFailover is the entire point. Without it this is a reboot in place,
      # which tests nothing about the standby.
      parameter {
        key   = "forceFailover"
        value = "true"
      }
    }
  }
}
