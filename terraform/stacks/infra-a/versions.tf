# ---------------------------------------------------------------------------
# stack: infra-a / providers and state
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70.0"
    }
  }

  # Partial config: the bucket and lock table are supplied at init time.
  #
  #   terraform init -backend-config=../../backend.hcl -backend-config="key=infra-a/terraform.tfstate"
  #
  # Remote state is not ceremony here. Two stacks get destroyed and rebuilt
  # repeatedly across chaos runs, and losing the state file of a half-built EKS
  # cluster means hand-deleting 40 resources through the console.
  #
  # `make validate` passes -backend=false, so nothing below is needed to lint.
  backend "s3" {}
}

provider "aws" {
  region = var.region

  # Applied on top of the per-resource tags. The stack tag is what Cost Explorer
  # groups by when producing the real-world half of the FinOps analysis.
  default_tags {
    tags = {
      Project   = "eks-resilience-finops"
      Stack     = "infra-a"
      Owner     = "allaouiyounespro"
      Portfolio = "github.com/allaouiyounespro"
      ManagedBy = "terraform"
    }
  }
}
