#!/usr/bin/env bash
# Run N chaos experiments against a live stack and aggregate them into a median.
# owner: allaouiyounespro / portfolio: github.com/allaouiyounespro
#
#   ./scripts/run-campaign.sh infra-b 3
#
# The stack must already be up (make up STACK=...). Rebuilding between runs would
# cost 35 minutes of EKS create/delete each time and would measure a *cold*
# cluster three times instead of the same cluster three times.
#
# Each run is: reset to the starting state -> inject -> observe -> report.
# The reset is not optional; see scripts/reset-stack.sh for what it prevents.

set -euo pipefail

STACK="${1:?usage: run-campaign.sh <infra-a|infra-b> [runs]}"
RUNS="${2:-3}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAMPAIGN_DIR="${REPO_ROOT}/results/${STACK}"

echo "=================================================================="
echo " campaign: ${RUNS} run(s) against ${STACK}"
echo "=================================================================="

BEFORE="$(ls -1d "${CAMPAIGN_DIR}"/*/ 2>/dev/null | wc -l || echo 0)"

for i in $(seq 1 "${RUNS}"); do
  echo
  echo "------------------------------------------------------------------"
  echo " run ${i}/${RUNS}"
  echo "------------------------------------------------------------------"

  # Between runs, put the stack back exactly where run #1 found it. On the first
  # run this is a no-op that doubles as a pre-flight health gate - if the stack
  # is not at full strength before the first fault, there is no point injecting
  # one.
  "${REPO_ROOT}/scripts/reset-stack.sh" "${STACK}"

  "${REPO_ROOT}/scripts/run-experiment.sh" "${STACK}"

  if [[ "${i}" -lt "${RUNS}" ]]; then
    # A short breather so CloudWatch, the ALB target group and Karpenter's
    # consolidation loop all settle before the next reset inspects them.
    echo "==> cooling down for 120s before the next run"
    sleep 120
  fi
done

echo
echo "=================================================================="
echo " aggregating"
echo "=================================================================="

# Only the runs this campaign produced. A bare glob would sweep in every previous
# run ever recorded for this stack - including ones from a different instance
# size, a different chaos duration, or a broken build - and quietly fold them
# into the median.
mapfile -t RESULTS < <(ls -1dt "${CAMPAIGN_DIR}"/*/ | head -n "${RUNS}" | sed 's|$|result.json|')

for r in "${RESULTS[@]}"; do
  [[ -f "${r}" ]] || { echo "missing ${r} - a run did not produce a report" >&2; exit 1; }
done

python3 -m chaos.aggregate \
  --stack "${STACK}" \
  --out "${CAMPAIGN_DIR}/aggregate.json" \
  "${RESULTS[@]}"

echo
echo "==> table for docs/results.md:"
echo
python3 -m chaos.aggregate --stack "${STACK}" --markdown "${RESULTS[@]}"
echo
echo "==> aggregate written to ${CAMPAIGN_DIR}/aggregate.json"
echo "    ${#RESULTS[@]} run(s) aggregated; ${BEFORE} earlier run(s) in this directory were NOT included"
