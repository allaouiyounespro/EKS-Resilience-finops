#!/usr/bin/env bash
# Pull the campaign's time series out of Prometheus before the cluster dies.
# owner: allaouiyounespro
#
#   ./scripts/export-metrics.sh infra-a
#
# Prometheus lives inside the cluster, on an EBS volume that `terraform destroy`
# deletes. Every graph, every sample, every trace of what the system did during
# the fault goes with it. This is the one artefact of the experiment that cannot
# be re-derived afterwards, and there is exactly one chance to save it.
#
# So: run this after the campaign, before the teardown. It writes raw JSON that
# outlives the cluster, is versionable, and can be re-analysed by anyone who does
# not trust the graph.

set -euo pipefail

STACK="${1:?usage: export-metrics.sh <infra-a|infra-b>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/results/${STACK}/metrics"
PORT="${PROM_PORT:-9091}"

# Cover the whole campaign with room to spare, at 15s resolution - the same
# granularity Prometheus scraped at, so nothing is smoothed away.
LOOKBACK="${LOOKBACK:-4h}"
STEP="${STEP:-15s}"

mkdir -p "${OUT_DIR}"

echo "==> port-forwarding Prometheus on :${PORT}"
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus "${PORT}:9090" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT

for _ in {1..30}; do
  curl -sf "http://localhost:${PORT}/-/ready" >/dev/null 2>&1 && break
  sleep 1
done
curl -sf "http://localhost:${PORT}/-/ready" >/dev/null || {
  echo "Prometheus did not become reachable - is the monitoring stack up?" >&2
  exit 1
}

END=$(date -u +%s)
START=$(python3 -c "print($END - $(python3 - <<PY
u="${LOOKBACK}"
print({'h':3600,'m':60,'s':1}[u[-1]] * int(u[:-1]))
PY
))")

# The series that tell the story. Each is one file, named for what it answers.
declare -A QUERIES=(
  [availability]='witness:write_success:ratio_rate1m'
  [ready-pods-total]='witness:ready_pods:total'
  [ready-pods-by-zone]='witness:ready_pods:by_zone'
  [serving-zones]='witness:serving_zones:count'
  [write-latency-p99]='witness:write_latency:p99_1m'
  [karpenter-launches]='karpenter:nodeclaims_launched:rate5m'
  [pods-pending]='sum(kube_pod_status_phase{namespace="witness",phase="Pending"})'
  [pods-running]='sum(kube_pod_status_phase{namespace="witness",phase="Running"})'
  [nodes-by-zone]='count by (topology_kubernetes_io_zone) (kube_node_labels)'
)

echo "==> exporting ${#QUERIES[@]} series (${LOOKBACK} back, ${STEP} step)"

for name in "${!QUERIES[@]}"; do
  file="${OUT_DIR}/${name}.json"

  curl -sfG "http://localhost:${PORT}/api/v1/query_range" \
    --data-urlencode "query=${QUERIES[$name]}" \
    --data-urlencode "start=${START}" \
    --data-urlencode "end=${END}" \
    --data-urlencode "step=${STEP}" \
    -o "${file}" || { echo "  ${name}: query failed"; continue; }

  points=$(jq '[.data.result[].values[]] | length' "${file}" 2>/dev/null || echo 0)

  # A query that returns zero points is not evidence, it is an empty file that
  # looks like evidence. Say so rather than letting it sit in results/.
  if [[ "${points}" -eq 0 ]]; then
    echo "  ${name}: EMPTY - the metric does not exist or was never scraped"
  else
    printf "  %-20s %s points\n" "${name}" "${points}"
  fi
done

echo
echo "==> written to ${OUT_DIR}"
echo "    These files outlive the cluster. Everything else in Prometheus does not."
