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
#   Run #1 forces the RDS writer to fail over from eu-west-3a to its standby in
#   eu-west-3b. The FIS template, however, targets eu-west-3a - that AZ is baked
#   into the template at terraform apply time and does not follow the database.
#
#   So run #2 isolates an AZ that no longer holds the writer. The database is
#   never touched. Fewer pods die. The RTO comes out flatteringly low, the
#   result.json looks completely normal, and the median across the three runs is
#   quietly meaningless.
#
#   Nothing errors. Nothing warns. That is what makes it dangerous.
#
# So: fail the writer back to the target AZ, wait for the workload to return to
# full strength, and only then hand control back to the runner.

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
# 1. Database placement
# ---------------------------------------------------------------------------
current_az() {
  aws rds describe-db-instances \
    --db-instance-identifier "${DB_ID}" \
    --region "${REGION}" \
    --query 'DBInstances[0].AvailabilityZone' --output text
}

wait_available() {
  local deadline=$(( SECONDS + 900 ))
  while [[ ${SECONDS} -lt ${deadline} ]]; do
    local status
    status="$(aws rds describe-db-instances \
      --db-instance-identifier "${DB_ID}" --region "${REGION}" \
      --query 'DBInstances[0].DBInstanceStatus' --output text)"
    [[ "${status}" == "available" ]] && return 0
    printf '\r    database: %-24s' "${status}"
    sleep 15
  done
  echo >&2
  echo "database never returned to 'available'" >&2
  return 1
}

DB_AZ="$(current_az)"
echo "    database is in ${DB_AZ}"

if [[ "${DB_MULTI_AZ}" == "true" && "${DB_AZ}" != "${TARGET_AZ}" ]]; then
  # The writer drifted out of the blast radius during the previous run. Fail it
  # back so the next run injects the same fault the first one did.
  echo "    writer drifted out of the target AZ - failing back to ${TARGET_AZ}"

  aws rds reboot-db-instance \
    --db-instance-identifier "${DB_ID}" \
    --force-failover \
    --region "${REGION}" >/dev/null

  sleep 20
  wait_available
  echo

  DB_AZ="$(current_az)"
  echo "    database is now in ${DB_AZ}"

  if [[ "${DB_AZ}" != "${TARGET_AZ}" ]]; then
    # A Multi-AZ failover swaps writer and standby, so one failback is normally
    # enough. Landing somewhere else means the standby is not where we think it
    # is - and guessing would produce exactly the silent corruption this script
    # exists to prevent.
    echo >&2
    echo "ABORT: expected the writer in ${TARGET_AZ}, found it in ${DB_AZ}." >&2
    echo "The next run would isolate an AZ that does not hold the database, and" >&2
    echo "would report a low RTO for the wrong reason. Investigate before rerunning." >&2
    exit 1
  fi

elif [[ "${DB_MULTI_AZ}" != "true" && "${DB_AZ}" != "${TARGET_AZ}" ]]; then
  # A single-AZ instance is pinned by terraform and cannot move on its own. If it
  # has, someone changed the stack underneath us.
  echo >&2
  echo "ABORT: single-AZ database is in ${DB_AZ}, not the pinned ${TARGET_AZ}." >&2
  exit 1

else
  echo "    writer already in the target AZ - no failback needed"
fi

# ---------------------------------------------------------------------------
# 2. Workload
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
# 3. Placement sanity
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
