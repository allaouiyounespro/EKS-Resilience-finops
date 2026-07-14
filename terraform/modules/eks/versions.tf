# ---------------------------------------------------------------------------
# module: eks / provider constraints
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
#
# aws >= 5.70 because aws_eks_addon.pod_identity_association is how the EBS CSI
# driver gets its role here. The tls provider is gone: it existed only to
# fingerprint the OIDC issuer for IRSA, and Pod Identity made that whole dance
# unnecessary.
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
