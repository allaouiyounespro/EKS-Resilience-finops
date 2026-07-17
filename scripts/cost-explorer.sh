#!/usr/bin/env bash
# What the two architectures have ACTUALLY cost, according to AWS.
# owner: allaouiyounespro / portfolio: github.com/allaouiyounespro
#
#   ./scripts/cost-explorer.sh [days]
#
# The cost model in finops/ is a model. This is the bill.
#
# Reconciling the two is the part of a FinOps exercise that people skip, and it
# is the only part that proves the model is not fiction. Expect them to disagree
# by a few percent - the model ignores request-level charges, tiny API costs, and
# the free-tier boundaries that AWS applies per-account. Expect them NOT to
# disagree by 40%; if they do, the model is missing a line item and the break-even
# is wrong.
#
# Requires the CostProfile tag to be activated as a cost allocation tag in the
# Billing console. AWS does not do this automatically, and until it is done this
# script returns an empty result rather than an error - which is a genuinely
# confusing failure mode, so it is checked for explicitly below.

set -euo pipefail

DAYS="${1:-30}"
END="$(date -u +%Y-%m-%d)"
START="$(date -u -d "${DAYS} days ago" +%Y-%m-%d)"

command -v aws >/dev/null || { echo "aws cli not found" >&2; exit 1; }
command -v jq  >/dev/null || { echo "jq not found" >&2; exit 1; }

echo "==> actual spend, ${START} to ${END}, grouped by architecture"
echo

RESULT="$(
  aws ce get-cost-and-usage \
    --time-period "Start=${START},End=${END}" \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --filter '{"Tags":{"Key":"Project","Values":["eks-resilience-finops"]}}' \
    --group-by '[{"Type":"TAG","Key":"CostProfile"}]' \
    --output json 2>/dev/null || echo '{}'
)"

group_count="$(jq -r '[.ResultsByTime[]?.Groups[]?] | length' <<<"${RESULT}")"

if [[ "${group_count}" == "0" || -z "${group_count}" ]]; then
  echo "  No data." >&2
  echo >&2
  echo "  The usual cause is not a missing stack - it is that the CostProfile tag" >&2
  echo "  has not been activated as a cost allocation tag. AWS does not do this for" >&2
  echo "  you, and until it is done Cost Explorer cannot group by it:" >&2
  echo >&2
  echo "    Billing console -> Cost allocation tags -> activate 'CostProfile' and 'Project'" >&2
  echo >&2
  echo "  Note that activation is NOT retroactive: costs incurred before you flip" >&2
  echo "  that switch are never grouped by the tag. Do it before you build anything." >&2
  exit 1
fi

jq -r '
  .ResultsByTime[] |
  .TimePeriod.Start as $start |
  .Groups[] |
  "  \($start)  \(.Keys[0] | sub("CostProfile\\$"; "") | if . == "" then "(untagged)" else . end)  \(.Metrics.UnblendedCost.Amount | tonumber | . * 100 | round / 100) \(.Metrics.UnblendedCost.Unit)"
' <<<"${RESULT}"

echo
echo "==> the model's prediction, for comparison"
python3 -m finops.cost_model --json | jq -r '
  "  infra-a  \(.infra_a.total) USD/month (modelled)",
  "  infra-b  \(.infra_b.total) USD/month (modelled)",
  "  delta    \(.monthly_delta) USD/month"
'

echo
echo "  A few percent of disagreement is expected and healthy."
echo "  Tens of percent means the model is missing a line item - find it before"
echo "  quoting the break-even to anyone."
