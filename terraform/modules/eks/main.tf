# ---------------------------------------------------------------------------
# module: eks
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
#
# Identity note: this module uses EKS Pod Identity, not IRSA. IRSA needs an
# OIDC provider, a tls data source to fingerprint its certificate, and a trust
# policy with two StringEquals conditions that break silently when the service
# account is renamed. Pod Identity replaces all of that with one association
# resource per workload, and the eks-pod-identity-agent addon below is the only
# moving part. IRSA is still the right answer for cross-account roles; nothing
# here crosses an account.
# ---------------------------------------------------------------------------

data "aws_partition" "current" {}

locals {
  tags = merge(
    var.tags,
    {
      Module = "eks"
      Owner  = "allaouiyounespro"
    },
  )

  # EKS-managed addons. Versions are not pinned on purpose: EKS resolves the
  # default compatible with the control plane, and a pinned addon that lags the
  # control plane is a classic cause of a cluster that comes back from chaos
  # with CoreDNS crash-looping.
  #
  # configuration_values on the CNI turns on native NetworkPolicy enforcement -
  # the eBPF agent ships in the addon, it just defaults to off, and without it
  # every NetworkPolicy manifest in k8s/ is silently a no-op.
  addons = {
    vpc-cni = {
      before_compute = true
      configuration  = jsonencode({ enableNetworkPolicy = "true" })
    }
    kube-proxy = {
      before_compute = true
      configuration  = null
    }
    coredns = {
      before_compute = false
      configuration  = null
    }
    eks-pod-identity-agent = {
      before_compute = true
      configuration  = null
    }
  }
}

# ---------------------------------------------------------------------------
# KMS key for Kubernetes secret envelope encryption
#
# Without this, Kubernetes Secrets sit in etcd protected only by etcd's own
# volume encryption. With it, every Secret is additionally wrapped by a key this
# account controls - which is the difference between "AWS could read the witness
# DB password" and "nobody without kms:Decrypt on this key can".
# ---------------------------------------------------------------------------

resource "aws_kms_key" "secrets" {
  description             = "${var.name} - EKS secret envelope encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = local.tags
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.name}-eks-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# ---------------------------------------------------------------------------
# Control plane
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy",
  ])

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

# Created explicitly rather than letting EKS create it implicitly, so that the
# retention window is under Terraform's control instead of defaulting to
# "never expire" and quietly accruing cost forever.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.log_retention_days

  tags = local.tags
}

resource "aws_eks_cluster" "this" {
  name     = var.name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  enabled_cluster_log_types = var.enabled_log_types

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.public_access_cidrs
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.secrets.arn
    }
    resources = ["secrets"]
  }

  access_config {
    # API_AND_CONFIG_MAP rather than the legacy aws-auth ConfigMap alone: access
    # entries are declarative, so a cluster rebuilt after a destructive chaos run
    # comes back reachable without a manual kubectl patch.
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = local.tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# ---------------------------------------------------------------------------
# Node IAM role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    # SSM is not decoration: when an AZ is being disrupted, SSM Session Manager
    # is the only way onto a node whose subnet no longer routes to the internet.
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# ---------------------------------------------------------------------------
# Launch template for the system node group
#
# aws_eks_node_group alone cannot do two things this project requires:
#
#   1. enforce IMDSv2. Without http_tokens = "required", any pod that can reach
#      169.254.169.254 can steal the node's IAM credentials with one curl - the
#      exact SSRF-to-cloud-credentials path that took down Capital One.
#   2. tag the actual EC2 instances. Tags on the node group resource stay on the
#      node group; the instances underneath come up bare, invisible to Cost
#      Explorer, and the FinOps half of this project stops being able to see a
#      third of the compute bill.
#
# Both are launch template features, so a launch template it is.
# ---------------------------------------------------------------------------

resource "aws_launch_template" "system" {
  name_prefix = "${var.name}-system-"

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"

    # Hop limit 2, not 1: the EBS CSI driver reads instance metadata from a pod
    # network namespace (one hop through the bridge), and at hop limit 1 its
    # requests die silently and every PVC mount fails with an error that names
    # neither IMDS nor the hop limit. The application NodePool stays at hop 1 -
    # the witness has no business talking to IMDS at all.
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.system_node_group.disk_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # This is what actually puts tags on the instances, their volumes and their
  # ENIs - the three resources that otherwise show up in Cost Explorer as
  # anonymous spend.
  dynamic "tag_specifications" {
    for_each = toset(["instance", "volume", "network-interface"])

    content {
      resource_type = tag_specifications.value
      tags          = merge(local.tags, { Name = "${var.name}-system" })
    }
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-system"
  node_role_arn   = aws_iam_role.node.arn

  # Workload subnets only. In infra-a that list has one entry, so every system
  # pod - Karpenter included - sits in one AZ by construction.
  subnet_ids = var.node_subnet_ids

  instance_types = var.system_node_group.instance_types
  capacity_type  = var.system_node_group.capacity_type

  launch_template {
    id      = aws_launch_template.system.id
    version = aws_launch_template.system.latest_version
  }

  scaling_config {
    min_size     = var.system_node_group.min_size
    max_size     = var.system_node_group.max_size
    desired_size = var.system_node_group.desired_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    "workload-class" = "system"
  }

  tags = merge(local.tags, { Name = "${var.name}-system" })

  lifecycle {
    # The whole point of the experiment is that capacity moves. Terraform must
    # not fight the autoscaler by reverting desired_size on the next apply.
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

# ---------------------------------------------------------------------------
# Addons
#
# before_compute addons are installed before the node group so that the first
# node to join already has a working CNI; the rest follow, since CoreDNS cannot
# reach Ready with zero nodes to schedule on.
# ---------------------------------------------------------------------------

resource "aws_eks_addon" "before_compute" {
  for_each = { for k, v in local.addons : k => v if v.before_compute }

  cluster_name = aws_eks_cluster.this.name
  addon_name   = each.key

  configuration_values = each.value.configuration

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.tags
}

resource "aws_eks_addon" "after_compute" {
  for_each = { for k, v in local.addons : k => v if !v.before_compute }

  cluster_name = aws_eks_cluster.this.name
  addon_name   = each.key

  configuration_values = each.value.configuration

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.tags

  depends_on = [aws_eks_node_group.system]
}

# ---------------------------------------------------------------------------
# EBS CSI driver
#
# Not optional decoration: the in-tree EBS provisioner was removed from
# Kubernetes in 1.27. Without this addon, the Prometheus PVC in
# k8s/monitoring/ sits Pending forever with an event message that blames the
# StorageClass rather than the missing driver - and the monitoring stack that
# is supposed to witness the experiment never starts.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "pod_identity_assume" {
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

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "aws-ebs-csi-driver"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi.arn
    service_account = "ebs-csi-controller-sa"
  }

  tags = local.tags

  depends_on = [aws_eks_node_group.system]
}

# ---------------------------------------------------------------------------
# Access entries
# ---------------------------------------------------------------------------

resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.cluster_admin_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"

  tags = local.tags
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = toset(var.cluster_admin_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}
