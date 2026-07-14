#!/usr/bin/env bash
# Run one AZ-failure experiment end to end and report RTO and RPO.
# owner: allaouiyounespro / portfolio: github.com/allaouiyounespro
#
#   ./scripts/run-experiment.sh infra-a
#
# Ordering matters here and is not negotiable:
#
#   1. probes start FIRST and run from outside the cluster
#   2. a baseline is established - if the system is already unhealthy, the run is
#      aborted, because you cannot measure a recovery from a state that was never
#      healthy
#   3. only then is the fault injected
#   4. probes keep running well past the end of the fault, because recovery is
#      the thing being measured and it does not politely finish when FIS does
#
# Steps 2 and 4 are the ones people skip, and skipping either produces a number
# that looks like an RTO and is not one.

set -euo pipefail

STACK="${1:?usage: run-experiment.sh <infra-a|infra-b>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_DIR="${REPO_ROOT}/terraform/stacks/${STACK}"
RESULTS_DIR="${REPO_ROOT}/results/${STACK}/$(date -u +%Y%m%dT%H%M%SZ)"

BASELINE_SECONDS="${BASELINE_SECONDS:-60}"
# Observe for 10 minutes past the end of the fault. FIS restarts the stopped
# instances when its duration elapses, but "the instances are back" is not "the
# service is back" - nodes still have to join, pods still have to schedule and
# pass readiness. In infra-a most of the recovery happens in this window, and a
# probe that stopped when FIS did would report the outage as never having ended.
SETTLE_SECONDS="${SETTLE_SECONDS:-600}"

for tool in terraform aws jq python3; do
  command -v "${tool}" >/dev/null || { echo "missing required tool: ${tool}" >&2; exit 1; }
done

mkdir -p "${RESULTS_DIR}"

echo "==> reading terraform outputs for ${STACK}"
OUT="$(terraform -chdir="${STACK_DIR}" output -json)"

REGION="$(jq -r '.region.value' <<<"${OUT}")"
TEMPLATE_ID="$(jq -r '.fis_experiment_template_id.value' <<<"${OUT}")"
TARGET_AZ="$(jq -r '.fis_target_az.value' <<<"${OUT}")"

echo "==> resolving the load balancer"
# The address lives on the Gateway's status, written there by the AWS Load
# Balancer Controller once the ALB exists. Empty means the controller has not
# reconciled yet - or was never installed, which fails identically and is why
# the check is loud about both possibilities.
GATEWAY_HOST="$(
  kubectl -n witness get gateway witness \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true
)"
[[ -n "${GATEWAY_HOST}" ]] || {
  echo "the witness Gateway has no address - run bootstrap-cluster.sh first," >&2
  echo "and if you already did, read the aws-load-balancer-controller logs" >&2
  exit 1
}

BASE_URL="http://${GATEWAY_HOST}"
echo "    endpoint:  ${BASE_URL}"
echo "    target AZ: ${TARGET_AZ}"
echo "    results:   ${RESULTS_DIR}"

# ---------------------------------------------------------------------------
# Probes, started before anything is broken
# ---------------------------------------------------------------------------
echo "==> starting probes"
python3 -m chaos.probe \
  --url "${BASE_URL}/readyz" \
  --out "${RESULTS_DIR}/probe.ndjson" \
  --interval 1 --timeout 3 &
PROBE_PID=$!

python3 -m chaos.writer \
  --url "${BASE_URL}" \
  --out "${RESULTS_DIR}/acks.ndjson" \
  --interval 1 --timeout 5 &
WRITER_PID=$!

# Whatever happens next - a failed FIS call, an interrupted run, a Ctrl-C - the
# probes must be reaped. Orphaned probes silently keep appending to an NDJSON
# file that a later run will then analyse as if it were its own.
cleanup() {
  kill "${PROBE_PID}" "${WRITER_PID}" 2>/dev/null || true
  wait "${PROBE_PID}" "${WRITER_PID}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "==> establishing a ${BASELINE_SECONDS}s healthy baseline"
sleep "${BASELINE_SECONDS}"

BASELINE_FAILURES="$(grep -c '"ok": false' "${RESULTS_DIR}/probe.ndjson" 2>/dev/null || echo 0)"
if [[ "${BASELINE_FAILURES}" -gt 0 ]]; then
  echo >&2
  echo "ABORT: ${BASELINE_FAILURES} request(s) failed before the fault was even injected." >&2
  echo "The system is not healthy. Any RTO measured from here would be measuring" >&2
  echo "a pre-existing problem and attributing it to the experiment." >&2
  exit 1
fi
echo "    baseline clean"

# ---------------------------------------------------------------------------
# Inject
# ---------------------------------------------------------------------------
echo "==> starting FIS experiment ${TEMPLATE_ID}"
EXPERIMENT="$(
  aws fis start-experiment \
    --experiment-template-id "${TEMPLATE_ID}" \
    --region "${REGION}" \
    --output json
)"

EXPERIMENT_ID="$(jq -r '.experiment.id' <<<"${EXPERIMENT}")"

# FIS's own startTime, not the shell's. The gap between calling the API and the
# fault actually landing is routinely 10-20 seconds, and charging that to the
# architecture's RTO would be flattering nonsense.
FAULT_START_ISO="$(jq -r '.experiment.startTime' <<<"${EXPERIMENT}")"
FAULT_START="$(python3 -c "
import sys, datetime
raw = sys.argv[1].replace('Z', '+00:00')
print(datetime.datetime.fromisoformat(raw).timestamp())
" "${FAULT_START_ISO}")"

echo "    experiment:  ${EXPERIMENT_ID}"
echo "    fault start: ${FAULT_START_ISO} (${FAULT_START})"

echo "==> waiting for the experiment to finish"
while true; do
  STATE="$(
    aws fis get-experiment --id "${EXPERIMENT_ID}" --region "${REGION}" \
      --query 'experiment.state.status' --output text
  )"
  case "${STATE}" in
    completed|stopped|failed)
      echo "    experiment ${STATE}"
      break
      ;;
    *)
      printf '\r    state: %-12s' "${STATE}"
      sleep 15
      ;;
  esac
done
echo

if [[ "${STATE}" == "failed" ]]; then
  aws fis get-experiment --id "${EXPERIMENT_ID}" --region "${REGION}" \
    --query 'experiment.state.reason' --output text >&2
  echo "the fault did not land; there is nothing to measure" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Settle
# ---------------------------------------------------------------------------
echo "==> observing recovery for a further ${SETTLE_SECONDS}s"
echo "    (FIS is done, but the service is not necessarily back - that gap is the RTO)"
sleep "${SETTLE_SECONDS}"

echo "==> stopping probes"
cleanup
trap - EXIT INT TERM

# ---------------------------------------------------------------------------
# Read out and report
# ---------------------------------------------------------------------------
echo "==> reading final database state"
DB_LAST_SEQ="$(
  curl -sf --max-time 10 "${BASE_URL}/last" 2>/dev/null | jq -r '.last_seq // empty' || true
)"

DB_ARG=()
if [[ -n "${DB_LAST_SEQ}" ]]; then
  echo "    database last_seq=${DB_LAST_SEQ}"
  DB_ARG=(--db-last-seq "${DB_LAST_SEQ}")
else
  # Not a script bug. For infra-a this is a legitimate outcome: the database is
  # still gone. The report says so instead of inventing a number.
  echo "    database still unreachable - the report will say so"
fi

python3 -m chaos.report \
  --stack "${STACK}" \
  --probe "${RESULTS_DIR}/probe.ndjson" \
  --acks "${RESULTS_DIR}/acks.ndjson" \
  --fault-start "${FAULT_START}" \
  "${DB_ARG[@]}" \
  --out "${RESULTS_DIR}/result.json"

echo
echo "==> raw timelines kept at ${RESULTS_DIR}"
echo "    every number above can be re-derived from them; nothing is overwritten"
