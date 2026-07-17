#!/usr/bin/env bash
# Return a stack to the exact state run #1 started from.
# owner: allaouiyounespro / portfolio: github.com/allaouiyounespro
#
#   ./scripts/reset-stack.sh infra-b
#
# Run BETWEEN chaos runs. Without it, a campaign of three runs silently measures
# three different experiments.
#
# The trap this exists to close:
#
#   Run #1's fault forces the RDS writer onto its standby in another AZ. The FIS
#   template, however, targets the AZ it was applied with, and that does not
#   follow the database.
#
#   So run #2 isolates an AZ that no longer holds the writer. The database is
#   never touched. Fewer pods die. The RTO comes out flatteringly low, the
#   result.json looks completely normal, and the median across the three runs is
#   quietly meaningless.
#
#   Nothing errors. Nothing warns. That is what makes it dangerous.
#
# So: re-point the fault at wherever the writer is now, wait for the workload to
# return to full strength, and only then hand control back to the runner.

set -euo pipefail

STACK="${1:?usage: reset-stack.sh <infra-a|infra-b>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_DIR="${REPO_ROOT}/terraform/stacks/${STACK}"

EXPECTED_REPLICAS="${EXPECTED_REPLICAS:-6}"
SETTLE_TIMEOUT="${SETTLE_TIMEOUT:-900}"

for tool in terraform aws kubectl jq; do
  command -v "${tool}" >/dev/null || { echo "missing required tool: ${tool}" >&2; exit 1; }
done

OUT="$(terraform -chdir="${STACK_DIR}" output -json)"
REGION="$(jq -r '.region.value'         <<<"${OUT}")"
TARGET_AZ="$(jq -r '.fis_target_az.value' <<<"${OUT}")"
DB_MULTI_AZ="$(jq -r '.db_multi_az.value' <<<"${OUT}")"
DB_ID="$(jq -r '.db_endpoint.value' <<<"${OUT}" | cut -d. -f1)"

echo "==> resetting ${STACK} (target AZ: ${TARGET_AZ})"

# ---------------------------------------------------------------------------
# 1. Point the fault at wherever the writer actually is
#
# This used to force the writer BACK to the template's target AZ with
# reboot-db-instance --force-failover. It does not work reliably: on the infra-b
# campaign the failover reported "completed" in the RDS event log and left the
# writer exactly where it started. Two failovers, same AZ, no error anywhere.
#
# The premise was wrong anyway. A Multi-AZ failover swaps writer and standby
# between the two AZs RDS chose - you cannot aim it, you can only ask for a swap
# and hope. Building the experiment on top of that means every run depends on an
# operation with no guarantee of outcome, and it costs 40 seconds and a real
# mini-outage each time.
#
# Inverting it removes the whole problem: the FIS template already computes its
# target from module.rds.availability_zone, so a terraform apply re-reads where
# RDS actually put the writer and re-points the fault there. No failover, no
# hoping, and the invariant is stated rather than enforced: the fault always
# hits the AZ holding the writer.
# ---------------------------------------------------------------------------
echo "==> re-pointing the fault at the current writer"

DB_AZ="$(aws rds describe-db-instances \
  --db-instance-identifier "${DB_ID}" --region "${REGION}" \
  --query 'DBInstances[0].AvailabilityZone' --output text)"
echo "    writer is in ${DB_AZ}"

if [[ "${DB_AZ}" != "${TARGET_AZ}" ]]; then
  echo "    template targets ${TARGET_AZ} - updating it to ${DB_AZ}"

  terraform -chdir="${STACK_DIR}" apply -refresh-only -auto-approve -no-color >/dev/null
  terraform -chdir="${STACK_DIR}" apply -auto-approve -no-color >/dev/null

  OUT="$(terraform -chdir="${STACK_DIR}" output -json)"
  TARGET_AZ="$(jq -r '.fis_target_az.value' <<<"${OUT}")"
  echo "    template now targets ${TARGET_AZ}"
fi

if [[ "${DB_AZ}" != "${TARGET_AZ}" ]]; then
  # For a single-AZ stack the writer is pinned by terraform and cannot move; if
  # it has, someone changed the stack underneath us. For Multi-AZ, the apply
  # above should have converged. Either way, refusing beats measuring a fault
  # that misses the database.
  echo >&2
  echo "ABORT: the writer is in ${DB_AZ} and the fault targets ${TARGET_AZ}." >&2
  echo "The run would isolate an AZ with no database in it, complete happily, and" >&2
  echo "report a number that measures nothing." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. The system tier - checked BEFORE the workload, because it is what recovers
#    the workload
#
# The infra-a campaign taught this one the hard way. FIS stops every instance in
# the target AZ, including the system nodes. The managed node group's ASG launches
# replacements - and if it launches them into the AZ that is still cut off, they
# boot, fail to reach the control plane, never join, and sit there as zombies:
# `running` in EC2, status checks green, node group ACTIVE with no health issues,
# and completely invisible to Kubernetes.
#
# In infra-b two system nodes survive in the other AZs, so the cluster keeps
# working and nothing looks wrong. But Karpenter may be down to one replica, and
# starting run 2 with a degraded controller measures a crippled system rather than
# the architecture - which is exactly the class of quiet, plausible, wrong result
# this whole project exists to refuse.
# ---------------------------------------------------------------------------
echo "==> checking the system tier"

# Reap the zombies first.
#
# FIS stops the system nodes; the ASG launches replacements; and if it launches
# one into the AZ that is still cut off, that instance boots, cannot reach the
# control plane, never joins, and stays there. EC2 calls it `running` with green
# status checks. The node group calls itself ACTIVE with no health issues.
# Kubernetes has never heard of it. Nothing reconciles this, ever - infra-a's
# cluster had to be repaired by hand.
#
# Anything tagged for this cluster and running in EC2 but absent from `kubectl
# get nodes` is a zombie. Terminating it is the only thing that makes the ASG
# try again, now that the AZ is reachable.
CLUSTER="$(jq -r '.cluster_name.value' <<<"${OUT}")"

K8S_NODES="$(kubectl get nodes -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}' 2>/dev/null \
  | awk -F/ '{print $NF}' | grep -v '^$' | sort -u || true)"

EC2_NODES="$(aws ec2 describe-instances --region "${REGION}" \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER},Values=owned" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' '\n' | sort -u || true)"

ZOMBIES=""
for i in ${EC2_NODES}; do
  grep -qx "${i}" <<<"${K8S_NODES}" || ZOMBIES="${ZOMBIES} ${i}"
done

if [[ -n "${ZOMBIES// /}" ]]; then
  echo "    zombies (running in EC2, unknown to Kubernetes):${ZOMBIES}"
  echo "    terminating them so the ASG retries into a reachable AZ"
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --region "${REGION}" --instance-ids ${ZOMBIES} >/dev/null 2>&1 || true

  echo "    waiting for the system tier to come back"
  deadline=$(( SECONDS + 600 ))
  while [[ ${SECONDS} -lt ${deadline} ]]; do
    n="$(kubectl get nodes -l workload-class=system --no-headers 2>/dev/null | grep -c ' Ready' || true)"
    [[ "${n:-0}" -ge "$(jq -r '.workload_azs.value | length' <<<"${OUT}")" ]] && break
    printf '\r      %s node(s) Ready' "${n:-0}"
    sleep 20
  done
  echo
fi

SYSTEM_READY="$(kubectl get nodes -l workload-class=system --no-headers 2>/dev/null | grep -c ' Ready' || true)"
SYSTEM_READY="${SYSTEM_READY:-0}"
SYSTEM_EXPECTED="${EXPECTED_ZONES:-$(jq -r '.workload_azs.value | length' <<<"${OUT}")}"

KARPENTER_READY="$(
  kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo 0
)"

echo "    system nodes Ready: ${SYSTEM_READY}/${SYSTEM_EXPECTED}"
echo "    Karpenter replicas Running: ${KARPENTER_READY}"

if [[ "${SYSTEM_READY}" -lt "${SYSTEM_EXPECTED}" ]]; then
  echo >&2
  echo "ABORT: only ${SYSTEM_READY}/${SYSTEM_EXPECTED} system nodes are Ready, and" >&2
  echo "reaping the zombies did not bring them back. Something else is wrong -" >&2
  echo "check the node group's health and the subnets it launches into." >&2
  exit 1
fi

if [[ "${KARPENTER_READY}" -lt 1 ]]; then
  echo >&2
  echo "ABORT: no Karpenter replica is Running." >&2
  echo "Nothing would provision replacement capacity, so the next run would measure" >&2
  echo "a dead control loop rather than the architecture." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Workload
# ---------------------------------------------------------------------------
echo "==> waiting for the workload to return to full strength"

# Not just "rollout status": after a chaos run the Deployment can report itself
# Available while replacement pods are still being scheduled onto nodes Karpenter
# is only now launching. Count Ready replicas explicitly.
deadline=$(( SECONDS + SETTLE_TIMEOUT ))
while [[ ${SECONDS} -lt ${deadline} ]]; do
  ready="$(kubectl -n witness get deploy witness -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  ready="${ready:-0}"

  if [[ "${ready}" -ge "${EXPECTED_REPLICAS}" ]]; then
    echo "    ${ready}/${EXPECTED_REPLICAS} replicas Ready"
    break
  fi

  printf '\r    %s/%s replicas Ready' "${ready}" "${EXPECTED_REPLICAS}"
  sleep 10
done

if [[ "${ready:-0}" -lt "${EXPECTED_REPLICAS}" ]]; then
  echo >&2
  echo "ABORT: only ${ready}/${EXPECTED_REPLICAS} replicas Ready after ${SETTLE_TIMEOUT}s." >&2
  echo "Starting a run from a degraded state measures the previous incident, not this one." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Placement sanity
# ---------------------------------------------------------------------------
echo "==> zone spread"
kubectl -n witness get pods \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
  | sort -u \
  | while read -r node; do
      [[ -n "${node}" ]] || continue
      az="$(kubectl get node "${node}" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')"
      echo "${az}"
    done | sort | uniq -c | sed 's/^/    /'

# The pods must actually be spread. If a previous recovery packed everything into
# one surviving AZ and consolidation never rebalanced it, the next run's blast
# radius is not what the architecture claims - and infra-b would score like
# infra-a for a reason that has nothing to do with topology.
ZONES_WITH_PODS="$(
  kubectl -n witness get pods -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
    | sort -u | while read -r node; do
        [[ -n "${node}" ]] || continue
        kubectl get node "${node}" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}'
      done | sort -u | grep -c . || true
)"

EXPECTED_ZONES="$(jq -r '.workload_azs.value | length' <<<"${OUT}")"

if [[ "${ZONES_WITH_PODS}" -lt "${EXPECTED_ZONES}" ]]; then
  echo >&2
  echo "WARNING: pods occupy ${ZONES_WITH_PODS} zone(s), expected ${EXPECTED_ZONES}." >&2
  echo "The previous recovery left the workload packed. Delete a few pods and let the" >&2
  echo "scheduler rebalance, or this run's blast radius will not match run #1's." >&2
  exit 1
fi

echo
echo "==> ${STACK} is back to its starting state"
