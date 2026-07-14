#!/usr/bin/env bash
# Tear a stack down without leaving anything behind.
# owner: allaouiyounespro
#
#   ./scripts/teardown.sh infra-b
#
# `terraform destroy` on its own does not work here, and the reason is structural
# rather than a bug: three controllers create AWS resources that Terraform never
# learns about.
#
#   the ALB              created by the AWS Load Balancer Controller
#   Karpenter's nodes    created by Karpenter, not by any ASG
#   Prometheus's EBS     created by the EBS CSI driver from a PVC
#
# Terraform cannot delete what it cannot see. Worse, the first two hold ENIs in
# the subnets, so `destroy` fails on DependencyViolation - and the third simply
# survives, silently billing 1.86 USD/month per 20 GiB volume, forever. On the
# infra-a teardown it did exactly that, and nothing anywhere complained.
#
# So the order is: ask each controller to clean up its own mess, WAIT until AWS
# agrees it is gone, and only then let Terraform run.
#
# The graceful path also has to survive a broken cluster, because after a chaos
# run that is what you have. Every kubectl call below is best-effort; if the API
# server is unreachable, the sweep at the end catches what the controllers could
# not.

set -uo pipefail

STACK="${1:?usage: teardown.sh <infra-a|infra-b>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_DIR="${REPO_ROOT}/terraform/stacks/${STACK}"
REGION="${AWS_REGION:-eu-west-3}"

for tool in terraform aws kubectl jq; do
  command -v "${tool}" >/dev/null || { echo "missing: ${tool}" >&2; exit 1; }
done

CLUSTER="$(terraform -chdir="${STACK_DIR}" output -raw cluster_name 2>/dev/null || echo "")"
VPC="$(terraform -chdir="${STACK_DIR}" output -raw vpc_id 2>/dev/null || echo "")"

echo "==> tearing down ${STACK} (cluster: ${CLUSTER:-unknown})"

# ---------------------------------------------------------------------------
# 1. Ask the controllers to clean up after themselves
# ---------------------------------------------------------------------------
if kubectl cluster-info >/dev/null 2>&1; then
  echo "==> deleting the Gateway (the LB Controller owns the ALB)"
  kubectl delete gateway witness -n witness --ignore-not-found --timeout=3m || true

  # Deleting the PVCs is what triggers the CSI driver to delete the EBS volumes.
  # Skip it and the volumes outlive the cluster - which is precisely what happened
  # on infra-a, and precisely the kind of silent leak a FinOps project cannot have.
  echo "==> deleting PVCs (the CSI driver owns the EBS volumes)"
  kubectl delete pvc --all -n monitoring --ignore-not-found --timeout=3m || true

  # Karpenter's instances belong to no ASG and no node group. Nothing else in this
  # script or in Terraform will ever touch them. Deleting the NodePool makes
  # Karpenter terminate its own nodes, which is the only clean way.
  echo "==> deleting the Karpenter NodePool (Karpenter owns its instances)"
  kubectl delete nodepool witness --ignore-not-found --timeout=3m || true
  kubectl delete nodeclaims --all --ignore-not-found --timeout=3m || true
else
  echo "==> cluster API unreachable - skipping the graceful path"
  echo "    (expected after a chaos run; the sweep below will catch the orphans)"
fi

# ---------------------------------------------------------------------------
# 2. Wait for AWS to agree that they are actually gone
#
# The controllers return immediately; AWS takes its time. Running `destroy` before
# the ENIs are released just moves the failure later.
# ---------------------------------------------------------------------------
echo "==> waiting for AWS to release the load balancers and Karpenter instances"
deadline=$(( SECONDS + 300 ))
while [[ ${SECONDS} -lt ${deadline} ]]; do
  albs=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "length(LoadBalancers[?VpcId=='${VPC}'])" --output text 2>/dev/null || echo 0)
  karp=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:karpenter.sh/nodepool,Values=*" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo 0)

  if [[ "${albs}" == "0" && "${karp}" == "0" ]]; then
    echo "    clear"
    break
  fi
  printf '\r    %s load balancer(s), %s Karpenter instance(s) still up' "${albs}" "${karp}"
  sleep 15
done
echo

# ---------------------------------------------------------------------------
# 3. Terraform
# ---------------------------------------------------------------------------
echo "==> terraform destroy"
if terraform -chdir="${STACK_DIR}" destroy -auto-approve -input=false -no-color; then
  DESTROY_OK=true
else
  DESTROY_OK=false
  echo "    destroy failed - sweeping the orphans and retrying"
fi

# ---------------------------------------------------------------------------
# 4. Sweep whatever is left
#
# Security groups are the sting in the tail: the LB Controller, the VPC CNI and
# EKS each leave one behind, they cross-reference each other, and none can be
# deleted until its rules are revoked. They hold nothing and block the VPC.
# ---------------------------------------------------------------------------
if [[ "${DESTROY_OK}" != true && -n "${VPC}" ]]; then
  echo "==> revoking and deleting orphaned security groups in ${VPC}"

  SGS=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC}" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || true)

  for sg in ${SGS}; do
    for direction in IpPermissions IpPermissionsEgress; do
      rules=$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$sg" \
        --query "SecurityGroups[0].${direction}" --output json 2>/dev/null || echo "[]")
      [[ "$(jq length <<<"${rules}")" -eq 0 ]] && continue

      if [[ "${direction}" == "IpPermissions" ]]; then
        aws ec2 revoke-security-group-ingress --region "$REGION" --group-id "$sg" \
          --ip-permissions "${rules}" >/dev/null 2>&1 || true
      else
        aws ec2 revoke-security-group-egress --region "$REGION" --group-id "$sg" \
          --ip-permissions "${rules}" >/dev/null 2>&1 || true
      fi
    done
    aws ec2 delete-security-group --region "$REGION" --group-id "$sg" >/dev/null 2>&1 \
      && echo "    deleted ${sg}"
  done

  echo "==> retrying terraform destroy"
  terraform -chdir="${STACK_DIR}" destroy -auto-approve -input=false -no-color || {
    echo "destroy still failing - run ./scripts/panic.sh to see what is left" >&2
    exit 1
  }
fi

# ---------------------------------------------------------------------------
# 5. The silent leak
#
# An unattached EBS volume bills forever and appears in no Terraform state, no
# dashboard, and no alert. This is the one that gets you six months later.
# ---------------------------------------------------------------------------
echo "==> sweeping orphaned EBS volumes"
VOLS=$(aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=status,Values=available" \
  --query 'Volumes[?Tags[?Key==`kubernetes.io/created-for/pvc/name`]].VolumeId' \
  --output text 2>/dev/null || true)

for vol in ${VOLS}; do
  size=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$vol" \
    --query 'Volumes[0].Size' --output text)
  aws ec2 delete-volume --region "$REGION" --volume-id "$vol" >/dev/null 2>&1 \
    && echo "    deleted ${vol} (${size} GiB, was billing $(python3 -c "print(f'{$size * 0.0928:.2f}')") USD/month)"
done

# CloudWatch log groups outlive their cluster. Empty ones are free, but a busy
# control plane leaves gigabytes behind, and retention is not deletion.
echo "==> sweeping orphaned log groups"
for lg in $(aws logs describe-log-groups --region "$REGION" \
    --query "logGroups[?contains(logGroupName, '${CLUSTER:-__none__}')].logGroupName" \
    --output text 2>/dev/null || true); do
  aws logs delete-log-group --region "$REGION" --log-group-name "$lg" >/dev/null 2>&1 \
    && echo "    deleted ${lg}"
done

echo
echo "==> done. Verifying against AWS rather than against Terraform:"
echo
"${REPO_ROOT}/scripts/panic.sh"
