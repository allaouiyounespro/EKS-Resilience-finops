# ---------------------------------------------------------------------------
# module: karpenter
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
      Module = "karpenter"
      Owner  = "allaouiyounespro"
    },
  )

  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  queue_name = "karpenter-${var.cluster_name}"
}

# ---------------------------------------------------------------------------
# Interruption queue
#
# EC2 tells you a Spot instance is going away 2 minutes before it does, and that
# an instance is scheduled for retirement well before that. Karpenter consumes
# those events from here and cordons/drains proactively.
#
# This matters more than it looks for the experiment: without the queue, a Spot
# reclaim looks identical to an AZ failure in the metrics - a node just vanishes.
# With it, planned churn is drained gracefully and only the genuinely unplanned
# loss shows up as unavailability, so the measured RTO stays honest.
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "interruption" {
  name = local.queue_name

  # Karpenter's consumer loop polls continuously; 300s is the documented value and
  # is comfortably longer than the 2-minute Spot warning it has to act within.
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = merge(local.tags, { Name = local.queue_name })
}

data "aws_iam_policy_document" "interruption_queue" {
  statement {
    sid       = "EventBridgeToSQS"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.interruption.arn]

    # events.amazonaws.com only - an earlier draft also listed sqs.amazonaws.com,
    # which grants nothing EventBridge needs and widens the set of services that
    # can write into a queue Karpenter acts on. The SourceArn condition pins it
    # further: only THIS cluster's four interruption rules may deliver here, not
    # any EventBridge rule anyone in the account creates later.
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [for rule in aws_cloudwatch_event_rule.interruption : rule.arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.interruption.arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "interruption" {
  queue_url = aws_sqs_queue.interruption.url
  policy    = data.aws_iam_policy_document.interruption_queue.json
}

# The four event sources Karpenter knows how to react to. AWS Health events are
# the interesting one here: a real AZ impairment surfaces as one, so this rule is
# what a genuine version of the injected failure would trip in production.
locals {
  interruption_events = {
    health_event = {
      source      = "aws.health"
      detail_type = "AWS Health Event"
    }
    spot_interruption = {
      source      = "aws.ec2"
      detail_type = "EC2 Spot Instance Interruption Warning"
    }
    instance_rebalance = {
      source      = "aws.ec2"
      detail_type = "EC2 Instance Rebalance Recommendation"
    }
    instance_state_change = {
      source      = "aws.ec2"
      detail_type = "EC2 Instance State-change Notification"
    }
  }
}

resource "aws_cloudwatch_event_rule" "interruption" {
  for_each = local.interruption_events

  name        = "karpenter-${var.cluster_name}-${each.key}"
  description = "Karpenter interruption handling: ${each.value.detail_type}"

  event_pattern = jsonencode({
    source        = [each.value.source]
    "detail-type" = [each.value.detail_type]
  })

  tags = local.tags
}

resource "aws_cloudwatch_event_target" "interruption" {
  for_each = local.interruption_events

  rule      = aws_cloudwatch_event_rule.interruption[each.key].name
  target_id = "karpenter-interruption-queue"
  arn       = aws_sqs_queue.interruption.arn
}

# ---------------------------------------------------------------------------
# Node instance profile
#
# Karpenter launches raw EC2 instances, not an ASG, so it needs an instance
# profile to attach. The role is the same one the managed node group uses.
# ---------------------------------------------------------------------------

resource "aws_iam_instance_profile" "node" {
  name = "karpenter-${var.cluster_name}"
  role = var.node_role_name

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Controller role (EKS Pod Identity)
#
# Pod Identity instead of IRSA. The IRSA version of this trust policy carried
# two StringEquals conditions on the OIDC issuer that had to match the service
# account name and namespace exactly - rename either and the controller gets
# AccessDenied on every EC2 call with no hint why. Pod Identity moves that
# binding into the association resource below, where Terraform owns it, and the
# trust policy shrinks to one service principal.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "controller_assume" {
  statement {
    effect = "Allow"

    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "controller" {
  name               = "karpenter-controller-${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.controller_assume.json

  tags = local.tags
}

resource "aws_eks_pod_identity_association" "controller" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.controller.arn

  tags = local.tags
}

data "aws_iam_policy_document" "controller" {
  # Read-only discovery of what it is allowed to launch and where.
  statement {
    sid    = "AllowScopedEC2Read"
    effect = "Allow"

    actions = [
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
      "ec2:DescribeAvailabilityZones",
    ]

    resources = ["*"]
  }

  # Launching capacity. Scoped by region rather than by resource id, because the
  # resources being created do not exist yet at policy-evaluation time.
  statement {
    sid    = "AllowScopedEC2LaunchActions"
    effect = "Allow"

    actions = [
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
      "ec2:RunInstances",
      "ec2:CreateTags",
    ]

    resources = [
      "arn:${local.partition}:ec2:${local.region}:*:*",
      "arn:${local.partition}:ec2:${local.region}::image/*",
    ]
  }

  # Terminating capacity, restricted to instances Karpenter itself tagged. This
  # is the guardrail that stops a compromised controller from terminating the
  # system node group - or the database's EC2 neighbours.
  #
  # StringLike, not StringEquals. StringEquals compares against the literal
  # character "*", so the original version of this condition matched nothing:
  # Karpenter could not terminate its own nodes, consolidation silently failed,
  # and the bill crept up while every dashboard stayed green. The kind of bug
  # only an IAM policy simulator - or an invoice - ever finds.
  statement {
    sid    = "AllowScopedInstanceTermination"
    effect = "Allow"

    actions = [
      "ec2:TerminateInstances",
      "ec2:DeleteLaunchTemplate",
    ]

    resources = ["*"]

    condition {
      test     = "StringLike"
      variable = "ec2:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  # Handing the node role to the instances it launches. Scoped to that one role:
  # without the condition, this is a privilege-escalation primitive.
  statement {
    sid       = "AllowPassNodeRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${var.node_role_name}"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  statement {
    sid    = "AllowInstanceProfileManagement"
    effect = "Allow"

    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
    ]

    resources = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/*"]
  }

  # Resolving the EKS-optimised AMI id from the SSM public parameter path.
  statement {
    sid       = "AllowSSMReadAMI"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:${local.partition}:ssm:${local.region}::parameter/aws/service/*"]
  }

  # Karpenter bin-packs by price, so it needs the price list. Pricing is a
  # global endpoint and does not support resource-level permissions.
  statement {
    sid       = "AllowPricingRead"
    effect    = "Allow"
    actions   = ["pricing:GetProducts"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowInterruptionQueueActions"
    effect = "Allow"

    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage",
    ]

    resources = [aws_sqs_queue.interruption.arn]
  }

  statement {
    sid       = "AllowClusterEndpointLookup"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:${local.partition}:eks:${local.region}:${local.account_id}:cluster/${var.cluster_name}"]
  }
}

resource "aws_iam_policy" "controller" {
  name        = "karpenter-controller-${var.cluster_name}"
  description = "Karpenter controller permissions for ${var.cluster_name}"
  policy      = data.aws_iam_policy_document.controller.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "controller" {
  role       = aws_iam_role.controller.name
  policy_arn = aws_iam_policy.controller.arn
}

# ---------------------------------------------------------------------------
# Access entry
#
# Karpenter-launched nodes join the cluster as this role. Without an access entry
# of type EC2_LINUX the kubelet's certificate signing request is never approved
# and the node sits NotReady forever - which, mid-experiment, is indistinguishable
# from "the AZ is still down".
# ---------------------------------------------------------------------------

resource "aws_eks_access_entry" "node" {
  cluster_name  = var.cluster_name
  principal_arn = "arn:${local.partition}:iam::${local.account_id}:role/${var.node_role_name}"
  type          = "EC2_LINUX"

  tags = local.tags
}
