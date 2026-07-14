# ---------------------------------------------------------------------------
# module: lbc / IAM
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
# ---------------------------------------------------------------------------

data "aws_partition" "current" {}

locals {
  tags = merge(
    var.tags,
    {
      Module = "lbc"
      Owner  = "allaouiyounespro"
    },
  )
}

data "aws_iam_policy_document" "assume" {
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
  name               = "lbc-${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = local.tags
}

# The policy document is vendored verbatim from the controller's repository
# (docs/install/iam_policy.json) rather than re-derived by hand. It is long and
# it is ugly, and both of those are the point: every hand-trimmed version of
# this policy I have seen eventually broke on the one API call the trimmer did
# not know the controller made (usually elasticloadbalancing:AddTags during a
# listener update). When upgrading the controller chart, re-vendor the file
# from the matching tag - do not edit it in place.
resource "aws_iam_policy" "controller" {
  name        = "lbc-${var.cluster_name}"
  description = "AWS Load Balancer Controller permissions for ${var.cluster_name} (vendored from upstream)"
  policy      = file("${path.module}/iam_policy.json")

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "controller" {
  role       = aws_iam_role.controller.name
  policy_arn = aws_iam_policy.controller.arn
}

resource "aws_eks_pod_identity_association" "controller" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.controller.arn

  tags = local.tags
}
