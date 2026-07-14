# ---------------------------------------------------------------------------
# module: lbc (AWS Load Balancer Controller prerequisites)
# owner: allaouiyounespro
# portfolio: github.com/allaouiyounespro
#
# The controller itself is a Helm release applied by scripts/bootstrap-cluster.sh,
# for the same reason Karpenter's is: a terraform plan must not depend on the
# cluster API being reachable, because reachability is exactly what the chaos
# experiment takes away. This module owns only the AWS side - the IAM role and
# its Pod Identity association.
#
# This module exists because an earlier revision of this project shipped Service
# annotations that assumed the controller was present, and no controller. The
# Service sat with an empty status.loadBalancer forever, nothing errored, and
# the experiment had no endpoint to probe. Worth remembering: in Kubernetes, a
# missing controller does not fail - it just never succeeds.
# ---------------------------------------------------------------------------

variable "cluster_name" {
  description = "EKS cluster the controller reconciles Gateways for."
  type        = string
}

variable "namespace" {
  description = "Namespace the controller runs in."
  type        = string
  default     = "kube-system"
}

variable "service_account" {
  description = "Service account bound to the controller role via Pod Identity."
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "tags" {
  description = "Tags merged into every resource."
  type        = map(string)
  default     = {}
}
