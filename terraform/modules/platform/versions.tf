# ---------------------------------------------------------------------------
# module: platform / provider constraints
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
#
# 1.9 is the floor because the variable validations here reference *other*
# variables (workload_azs must be a subset of azs), which older Terraform
# rejects at parse time. aws >= 5.70 for Pod Identity support on addons.
# The tls provider is gone with IRSA.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70.0"
    }
  }
}
