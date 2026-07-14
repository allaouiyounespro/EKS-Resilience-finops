#!/usr/bin/env bash
# Bring a freshly-applied stack to the point where the experiment can run.
# owner: allaouiyounespro / portfolio: github.com/allaouiyounespro
#
#   ./scripts/bootstrap-cluster.sh infra-a
#
# Everything here is driven by `terraform output`. Nothing is hard-coded, and
# nothing is typed twice - if a cluster name or a queue URL appears in this
# script as a literal, that is a bug waiting for the next `terraform destroy`.
#
# Install order matters and is annotated inline. The short version: CRDs before
# the controllers that serve them, controllers before the objects they
# reconcile, and the workload dead last.

set -euo pipefail

STACK="${1:?usage: bootstrap-cluster.sh <infra-a|infra-b>}"
WITNESS_IMAGE="${WITNESS_IMAGE:?set WITNESS_IMAGE to the pushed witness image, e.g. ghcr.io/allaouiyounespro/witness:0.1.0}"

# Chart versions are pinned. A bootstrap that installs whatever
# shipped last night is a bootstrap that behaves differently on every run, and
# this project's entire premise is controlled comparison. Bump deliberately,
# against the EKS version in the stack variables, and check the Karpenter
# compatibility matrix first.
KARPENTER_VERSION="${KARPENTER_VERSION:-1.6.2}"
LBC_VERSION="${LBC_VERSION:-1.14.0}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.3.0}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_DIR="${REPO_ROOT}/terraform/stacks/${STACK}"

[[ -d "${STACK_DIR}" ]] || { echo "no such stack: ${STACK}" >&2; exit 1; }

for tool in terraform aws kubectl helm envsubst jq; do
  command -v "${tool}" >/dev/null || { echo "missing required tool: ${tool}" >&2; exit 1; }
done

aws sts get-caller-identity >/dev/null 2>&1 || {
  echo "AWS credentials are absent or expired - run your SSO login first" >&2
  exit 1
}

echo "==> reading terraform outputs for ${STACK}"
OUT="$(terraform -chdir="${STACK_DIR}" output -json)"

CLUSTER_NAME="$(jq -r '.cluster_name.value'                       <<<"${OUT}")"
CLUSTER_ENDPOINT="$(jq -r '.cluster_endpoint.value'               <<<"${OUT}")"
REGION="$(jq -r '.region.value'                                   <<<"${OUT}")"
VPC_ID="$(jq -r '.vpc_id.value'                                   <<<"${OUT}")"
DB_ENDPOINT="$(jq -r '.db_endpoint.value'                         <<<"${OUT}")"
DB_SECRET_ARN="$(jq -r '.db_secret_arn.value'                     <<<"${OUT}")"
INSTANCE_PROFILE="$(jq -r '.karpenter.value.instance_profile_name' <<<"${OUT}")"
INTERRUPTION_QUEUE="$(jq -r '.karpenter.value.interruption_queue'  <<<"${OUT}")"

# The AZs Karpenter is permitted to launch into, as a JSON array. In infra-a
# this is a single-element list, and that one line is what makes the whole
# experiment meaningful: Karpenter will have nowhere to go.
ZONES_JSON="$(jq -c '.workload_azs.value' <<<"${OUT}")"

# DB_HOST must be the bare hostname. terraform gives host:port, and Postgres
# will happily try to resolve "db...amazonaws.com:5432" as a hostname and fail
# with a DNS error that looks nothing like the real problem.
DB_HOST="${DB_ENDPOINT%%:*}"

export CLUSTER_NAME CLUSTER_ENDPOINT INSTANCE_PROFILE INTERRUPTION_QUEUE ZONES_JSON

echo "    cluster:      ${CLUSTER_NAME}"
echo "    region:       ${REGION}"
echo "    workload AZs: ${ZONES_JSON}"

echo "==> configuring kubectl"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}" >/dev/null

# ---------------------------------------------------------------------------
# Database credentials
#
# Pulled from the RDS-managed secret and pushed into a Kubernetes Secret over
# stdin. Never on the command line: anything in argv is world-readable in
# /proc/*/cmdline for as long as the process runs, and "the DB password showed
# up in ps output on a shared runner" is an incident report nobody enjoys
# writing.
# ---------------------------------------------------------------------------
echo "==> syncing database credentials from Secrets Manager"

kubectl apply -f "${REPO_ROOT}/k8s/workload/00-namespace.yaml"

aws secretsmanager get-secret-value \
  --secret-id "${DB_SECRET_ARN}" \
  --region "${REGION}" \
  --query SecretString --output text \
  | jq -rj '.password' \
  | kubectl -n witness create secret generic witness-db \
      --from-file=password=/dev/stdin \
      --dry-run=client -o yaml \
  | kubectl apply -f -

# ---------------------------------------------------------------------------
# Gateway API CRDs, then the AWS Load Balancer Controller
#
# The CRDs come from the upstream Gateway API release (standard channel), not
# from the controller chart - the API is Kubernetes-official, the controller is
# just one implementation of it. LBC reconciles the Gateway in k8s/workload/
# into an ALB; without it the Gateway sits addressless forever and nothing
# errors, which is exactly the failure mode that motivated the lbc terraform
# module's existence.
# ---------------------------------------------------------------------------
echo "==> installing Gateway API CRDs ${GATEWAY_API_VERSION}"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo "==> installing AWS Load Balancer Controller ${LBC_VERSION}"
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks >/dev/null

# region and vpcId are passed explicitly because the controller's fallback is
# IMDS - and the system nodes run IMDSv2 with a hop limit that pods should not
# rely on. Explicit beats discovered, every time someone has to debug it.
#
# No role annotation: credentials arrive via the Pod Identity association in
# terraform/modules/lbc. The service account NAME is the contract.
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version "${LBC_VERSION}" \
  --namespace kube-system \
  --set clusterName="${CLUSTER_NAME}" \
  --set region="${REGION}" \
  --set vpcId="${VPC_ID}" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set controllerConfig.featureGates.ALBGatewayAPI=true \
  --set nodeSelector.workload-class=system \
  --wait

# ---------------------------------------------------------------------------
# Karpenter
# ---------------------------------------------------------------------------
echo "==> installing Karpenter ${KARPENTER_VERSION}"
KARPENTER_VALUES="$(mktemp)"
trap 'rm -f "${KARPENTER_VALUES}"' EXIT

envsubst < "${REPO_ROOT}/k8s/karpenter/values.yaml.tpl" > "${KARPENTER_VALUES}"

helm upgrade --install karpenter \
  oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace kube-system \
  --values "${KARPENTER_VALUES}" \
  --wait

# The NodePool cannot be applied until the CRDs the Helm chart installs exist.
# --wait above covers the deployment, not the CRD registration, so this races
# roughly one run in five without the retry below.
echo "==> waiting for Karpenter CRDs"
for _ in {1..30}; do
  if kubectl get crd nodepools.karpenter.sh >/dev/null 2>&1; then break; fi
  sleep 2
done

echo "==> applying NodePool (zones: ${ZONES_JSON})"
envsubst < "${REPO_ROOT}/k8s/karpenter/nodepool.yaml.tpl" | kubectl apply -f -

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------
echo "==> installing kube-prometheus-stack"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null

# The gp3 StorageClass must exist before the Prometheus PVC asks for it.
kubectl apply -f "${REPO_ROOT}/k8s/monitoring/storageclass-gp3.yaml"

# The admin password is generated, handed to Helm through a file descriptor
# (never argv), and NOT echoed. Retrieve it later from the Secret the chart
# writes - printing credentials to a terminal puts them in scrollback, tmux
# buffers, and CI logs, which are three places passwords go to be found.
GRAFANA_PASSWORD="$(openssl rand -base64 24)"

helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --values "${REPO_ROOT}/k8s/monitoring/kube-prometheus-values.yaml" \
  --set-file grafana.adminPassword=<(printf '%s' "${GRAFANA_PASSWORD}") \
  --wait --timeout 10m

unset GRAFANA_PASSWORD

kubectl apply -f "${REPO_ROOT}/k8s/monitoring/servicemonitor-witness.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/monitoring/prometheusrule-resilience.yaml"

# Karpenter's own chart would create this ServiceMonitor - but only if the
# Prometheus Operator CRD already exists when Helm renders the chart, and we
# install Karpenter first. Helm skips the object silently. Applying it here, from
# a file, makes the scrape independent of install order.
#
# Missed once already: infra-a ran its whole first campaign with no Karpenter
# metrics at all, and the "Karpenter nodes" panel was empty for reasons nobody
# could see.
kubectl apply -f "${REPO_ROOT}/k8s/monitoring/servicemonitor-karpenter.yaml"

kubectl -n monitoring create configmap grafana-dashboard-resilience \
  --from-file=resilience.json="${REPO_ROOT}/k8s/monitoring/grafana-dashboard-resilience.json" \
  --dry-run=client -o yaml \
  | kubectl label -f - --local -o yaml grafana_dashboard=1 \
  | kubectl apply -f -

# ---------------------------------------------------------------------------
# Workload
# ---------------------------------------------------------------------------
echo "==> deploying the witness workload"
kubectl apply -f "${REPO_ROOT}/k8s/workload/10-rbac.yaml"

sed -e "s|PLACEHOLDER_DB_HOST|${DB_HOST}|g" \
    -e "s|WITNESS_IMAGE|${WITNESS_IMAGE}|g" \
    "${REPO_ROOT}/k8s/workload/20-deployment.yaml" \
  | kubectl apply -f -

kubectl apply -f "${REPO_ROOT}/k8s/workload/30-gateway.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/workload/40-pdb.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/workload/50-networkpolicy.yaml"

echo "==> waiting for the workload to become ready"
# 10 minutes, not the default 30 seconds: the first pods are Pending until
# Karpenter notices them, launches nodes, and those nodes join. That cold-start
# path is 2-4 minutes and is entirely normal - it is also, incidentally, the
# closest thing to a dry run of the recovery being measured.
kubectl -n witness rollout status deployment/witness --timeout=10m

echo "==> waiting for the Gateway to be assigned an address"
GATEWAY_HOST=""
for _ in {1..60}; do
  GATEWAY_HOST="$(kubectl -n witness get gateway witness \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  [[ -n "${GATEWAY_HOST}" ]] && break
  sleep 10
done
[[ -n "${GATEWAY_HOST}" ]] || {
  echo "the Gateway never got an address - check the aws-load-balancer-controller logs" >&2
  exit 1
}

echo
echo "==> ready"
kubectl -n witness get pods -o wide
echo
echo "    endpoint: http://${GATEWAY_HOST}"
echo
echo "    Grafana password:"
echo "      kubectl -n monitoring get secret kube-prometheus-stack-grafana \\"
echo "        -o jsonpath='{.data.admin-password}' | base64 -d"
echo "    kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"
echo
echo "    Next: ./scripts/run-experiment.sh ${STACK}"
