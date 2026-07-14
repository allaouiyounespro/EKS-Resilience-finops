# ---------------------------------------------------------------------------
# stack: infra-b / providers and state
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

  # Partial config, same as infra-a but with its own state key:
  #
  #   terraform init -backend-config=../../backend.hcl -backend-config="key=infra-b/terraform.tfstate"
  #
  # Separate state files, not workspaces. The two stacks are compared side by
  # side and sometimes run concurrently; a shared state would serialise them and
  # a workspace typo would apply infra-b's config over infra-a's resources.
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "eks-resilience-finops"
      Stack     = "infra-b"
      Owner     = "allaouiyounespro"
      Portfolio = "github.com/allaouiyounespro"
      ManagedBy = "terraform"
    }
  }
}
