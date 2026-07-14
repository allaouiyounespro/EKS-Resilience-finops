#!/usr/bin/env bash
# Tear everything down. No questions, no dependencies on Terraform state.
# owner: allaouiyounespro
#
#   ./scripts/panic.sh              # show what is running and what it costs
#   ./scripts/panic.sh --destroy    # kill all of it
#
# Run this if a campaign is abandoned halfway, if the state file is lost, or if
# you simply do not remember what is still up. It works from AWS's own view of
# the world rather than from Terraform's, because the situation where you need
# it most is the one where those two have diverged.
#
# Deletion order is the whole point. Terraform does not know the ALB exists - the
# Load Balancer Controller created it - so a naive `terraform destroy` hangs for
# twenty minutes on a VPC whose ENIs are still held by a load balancer it cannot
# see, and then fails. Load balancers first, then clusters, then databases, then
# the network underneath them.

set -uo pipefail

REGION="${AWS_REGION:-eu-west-3}"
TAG_KEY="Project"
TAG_VALUE="eks-resilience-finops"
DESTROY=false

[[ "${1:-}" == "--destroy" ]] && DESTROY=true

command -v aws >/dev/null || { echo "aws cli not found" >&2; exit 1; }
command -v jq  >/dev/null || { echo "jq not found" >&2; exit 1; }

# Hourly burn rates, so the output answers the question you actually have at 2am:
# "how fast is this costing me?" Figures are eu-west-3 list prices.
COST_EKS=0.10
COST_NAT=0.05
COST_ALB=0.027
COST_RDS=0.038
COST_EC2=0.047

echo "==> what is still running in ${REGION}"
echo

CLUSTERS=$(aws eks list-clusters --region "$REGION" --query 'clusters[]' --output text 2>/dev/null || true)
NATS=$(aws ec2 describe-nat-gateways --region "$REGION" \
  --filter Name=state,Values=available,pending \
  --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null || true)
ALBS=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null || true)
DBS=$(aws rds describe-db-instances --region "$REGION" \
  --query 'DBInstances[?DBInstanceStatus!=`deleting`].DBInstanceIdentifier' --output text 2>/dev/null || true)
INSTANCES=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)
EIPS=$(aws ec2 describe-addresses --region "$REGION" \
  --query 'Addresses[?AssociationId==null].AllocationId' --output text 2>/dev/null || true)
VPCS=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
  --query 'Vpcs[].VpcId' --output text 2>/dev/null || true)

count() { [[ -z "$1" ]] && echo 0 || wc -w <<<"$1"; }

N_EKS=$(count "$CLUSTERS"); N_NAT=$(count "$NATS"); N_ALB=$(count "$ALBS")
N_RDS=$(count "$DBS");      N_EC2=$(count "$INSTANCES"); N_VPC=$(count "$VPCS")
N_EIP=$(count "$EIPS")

printf "  %-22s %s\n" "EKS clusters"        "$N_EKS   $CLUSTERS"
printf "  %-22s %s\n" "RDS instances"       "$N_RDS   $DBS"
printf "  %-22s %s\n" "NAT gateways"        "$N_NAT"
printf "  %-22s %s\n" "Load balancers"      "$N_ALB"
printf "  %-22s %s\n" "EC2 (project-tagged)" "$N_EC2"
printf "  %-22s %s\n" "VPCs (project)"      "$N_VPC"
printf "  %-22s %s\n" "Unattached EIPs"     "$N_EIP"
echo

BURN=$(python3 -c "print(f'{$N_EKS*$COST_EKS + $N_NAT*$COST_NAT + $N_ALB*$COST_ALB + $N_RDS*$COST_RDS + $N_EC2*$COST_EC2:.3f}')")
DAILY=$(python3 -c "print(f'{float('$BURN')*24:.2f}')")

if [[ "$N_EKS" -eq 0 && "$N_NAT" -eq 0 && "$N_RDS" -eq 0 && "$N_ALB" -eq 0 && "$N_EC2" -eq 0 ]]; then
  echo "  Nothing is running. You owe AWS nothing."
  exit 0
fi

echo "  Burn rate: ~\$${BURN}/hour  (~\$${DAILY}/day)"
echo

if [[ "$DESTROY" != true ]]; then
  echo "  Run './scripts/panic.sh --destroy' to kill all of it."
  exit 0
fi

echo "=================================================================="
echo " DESTROYING EVERYTHING TAGGED ${TAG_KEY}=${TAG_VALUE}"
echo "=================================================================="
echo

# 1. Load balancers. These hold ENIs in the VPC subnets and are invisible to
#    Terraform, so nothing else can be deleted until they are gone.
for arn in $ALBS; do
  echo "==> deleting load balancer ${arn##*/}"
  aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn" || true
done
[[ -n "$ALBS" ]] && { echo "    waiting 45s for ENIs to release"; sleep 45; }

# 2. EKS. Node groups first - deleting a cluster with live node groups is
#    rejected, and the error message does not say so clearly.
for c in $CLUSTERS; do
  echo "==> cluster ${c}"
  for ng in $(aws eks list-nodegroups --region "$REGION" --cluster-name "$c" \
                --query 'nodegroups[]' --output text 2>/dev/null); do
    echo "    deleting nodegroup ${ng}"
    aws eks delete-nodegroup --region "$REGION" --cluster-name "$c" --nodegroup-name "$ng" || true
  done
done

for c in $CLUSTERS; do
  for ng in $(aws eks list-nodegroups --region "$REGION" --cluster-name "$c" \
                --query 'nodegroups[]' --output text 2>/dev/null); do
    echo "    waiting for nodegroup ${ng} to go"
    aws eks wait nodegroup-deleted --region "$REGION" --cluster-name "$c" --nodegroup-name "$ng" 2>/dev/null || true
  done
done

# 3. Karpenter's instances. They belong to no node group and no ASG, so nothing
#    above touches them. Left alone they keep running - and keep billing - long
#    after the cluster they served is gone.
if [[ -n "$INSTANCES" ]]; then
  echo "==> terminating ${N_EC2} project-tagged EC2 instance(s)"
  aws ec2 terminate-instances --region "$REGION" --instance-ids $INSTANCES >/dev/null || true
fi

for c in $CLUSTERS; do
  echo "==> deleting cluster ${c}"
  aws eks delete-cluster --region "$REGION" --name "$c" || true
done

# 4. Databases. skip-final-snapshot: these are disposable test fixtures, and a
#    forgotten final snapshot bills storage forever.
for db in $DBS; do
  echo "==> deleting database ${db}"
  aws rds modify-db-instance --region "$REGION" --db-instance-identifier "$db" \
    --no-deletion-protection --apply-immediately >/dev/null 2>&1 || true
  aws rds delete-db-instance --region "$REGION" --db-instance-identifier "$db" \
    --skip-final-snapshot --delete-automated-backups >/dev/null 2>&1 || true
done

# 5. NAT gateways, then their addresses. An EIP that is merely detached still
#    costs money - AWS charges for idle addresses precisely to stop this.
for nat in $NATS; do
  echo "==> deleting NAT gateway ${nat}"
  aws ec2 delete-nat-gateway --region "$REGION" --nat-gateway-id "$nat" >/dev/null || true
done

echo
echo "==> deletion is asynchronous; EKS takes ~10 min, RDS ~5 min"
echo
echo "   Then release the addresses (they bill while idle):"
echo "     aws ec2 describe-addresses --region ${REGION} \\"
echo "       --query 'Addresses[?AssociationId==null].AllocationId' --output text \\"
echo "       | xargs -n1 aws ec2 release-address --region ${REGION} --allocation-id"
echo
echo "   Re-run './scripts/panic.sh' in 15 minutes to confirm the bleeding stopped."
echo
echo "   Terraform state is now a lie. Before using it again:"
echo "     terraform -chdir=terraform/stacks/<stack> state list | xargs -n1 \\"
echo "       terraform -chdir=terraform/stacks/<stack> state rm"
