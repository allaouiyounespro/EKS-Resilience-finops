# ---------------------------------------------------------------------------
# module: vpc
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
#
# Layout: one /20 private + one /20 public subnet per AZ, carved out of the
# supplied /16. Private subnets host the EKS nodes and RDS; public subnets host
# the NAT Gateways and the internet-facing load balancer.
#
#   private  index 0..2   -> 10.x.0.0/20,  10.x.16.0/20,  10.x.32.0/20
#   public   index 8..10  -> 10.x.128.0/20, 10.x.144.0/20, 10.x.160.0/20
#
# The gap between the two ranges is deliberate: it leaves room to add an
# intra/database tier later without renumbering anything already deployed.
# ---------------------------------------------------------------------------

locals {
  az_count = length(var.azs)

  # One NAT Gateway total, or one per AZ. This single boolean is worth ~73 USD
  # a month between infra-a and infra-b, and it is also the difference between
  # "the AZ dies and everything dies with it" and "the AZ dies and the other
  # two keep talking to the internet".
  nat_count = var.single_nat_gateway ? 1 : local.az_count

  tags = merge(
    var.tags,
    {
      Module = "vpc"
      Owner  = "allaouiyounespro"
    },
  )
}

resource "aws_vpc" "this" {
  cidr_block = var.cidr

  # Both are required by the EKS VPC CNI and by RDS private DNS resolution.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = var.name })
}

# ---------------------------------------------------------------------------
# Subnets
# ---------------------------------------------------------------------------

resource "aws_subnet" "private" {
  count = local.az_count

  vpc_id            = aws_vpc.this.id
  availability_zone = var.azs[count.index]
  cidr_block        = cidrsubnet(var.cidr, 4, count.index)

  tags = merge(
    local.tags,
    {
      Name = "${var.name}-private-${var.azs[count.index]}"
      Tier = "private"

      # Internal load balancers may be placed here by the AWS LB Controller.
      "kubernetes.io/role/internal-elb" = "1"

      # Karpenter selects the subnets it launches nodes into via this tag. If it
      # is missing, provisioning silently finds zero subnets and pods stay Pending.
      "karpenter.sh/discovery" = var.cluster_name
    },
  )
}

resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id                  = aws_vpc.this.id
  availability_zone       = var.azs[count.index]
  cidr_block              = cidrsubnet(var.cidr, 4, count.index + 8)
  map_public_ip_on_launch = true

  tags = merge(
    local.tags,
    {
      Name                     = "${var.name}-public-${var.azs[count.index]}"
      Tier                     = "public"
      "kubernetes.io/role/elb" = "1"
    },
  )
}

# ---------------------------------------------------------------------------
# Internet egress
# ---------------------------------------------------------------------------

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = var.name })
}

resource "aws_eip" "nat" {
  count = local.nat_count

  domain = "vpc"

  tags = merge(local.tags, { Name = "${var.name}-nat-${count.index}" })

  # The EIP is useless until the IGW exists; without this the first apply of a
  # fresh account races and fails roughly one time in three.
  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.tags, { Name = "${var.name}-nat-${var.azs[count.index]}" })

  depends_on = [aws_internet_gateway.this]
}

# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = local.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ even when a single NAT is shared: it keeps the
# blast radius of a route change AZ-scoped, and it means flipping
# single_nat_gateway from true to false does not rewrite existing associations.
resource "aws_route_table" "private" {
  count = local.az_count

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-private-${var.azs[count.index]}" })
}

resource "aws_route" "private_default" {
  count = local.az_count

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"

  # With a shared NAT every AZ points at index 0 - which is exactly the
  # cross-AZ dependency the chaos experiment is designed to expose in infra-a.
  nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.this[0].id : aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "private" {
  count = local.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------------------------------------------------------------------------
# Flow logs
#
# During a chaos run these are the ground truth for "did the AZ actually get
# cut off", independent of whatever the application metrics claim.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc/${var.name}/flow-logs"
  retention_in_days = var.flow_logs_retention_days

  tags = local.tags
}

data "aws_iam_policy_document" "flow_logs_assume" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]

    resources = ["${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name               = "${var.name}-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume[0].json

  tags = local.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name   = "${var.name}-flow-logs"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn         = aws_iam_role.flow_logs[0].arn

  # 1-minute aggregation instead of the 10-minute default: an RTO measured in
  # seconds cannot be corroborated by evidence bucketed into 10-minute windows.
  max_aggregation_interval = 60

  tags = local.tags
}
