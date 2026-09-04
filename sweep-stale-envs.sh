#!/usr/bin/env bash
# The scheduled ephemeral sweep (mootmaker/designs/ci-cd-pipeline.md, rollout step 11).
#
# Non-interactive counterpart to cleanup-stale-envs.sh. That script is for a human at a keyboard:
# it lists what it finds and asks per environment. This one runs unattended on a schedule, so it
# REPORTS BY DEFAULT and only acts when given --destroy - the design asks for report-only first,
# graduating to automatic teardown after a clean trial period, and this is the flag that graduates
# it. Neither script replaces the other.
#
# Three separate things get swept, deliberately reported apart because they mean different things:
#
#   1. Ephemeral environments with live infrastructure. Real AWS resources, really costing money,
#      stranded by an interrupted run. This is what the design was written for.
#   2. Ephemeral environments whose state is already empty. terraform destroy empties a state file
#      but does not delete the S3 object, and the release pipeline's build jobs call each
#      component's undeploy.sh directly rather than teardown-ephemeral-env.sh (which is the only
#      thing that removes the object). So every release leaves one or two of these behind. Nothing
#      is running; it is pure bookkeeping noise. Cheap to clean, and not urgent.
#   3. Orphaned Lambda log groups - a group whose function no longer exists. terraform destroy
#      removes the function but NOT the log group Lambda auto-created on first invocation, so these
#      accumulate forever and retain forever (mootmaker#47). Also noise rather than spend: the whole
#      account's log storage is a few MB. The cost is that describe-log-groups and any Logs Insights
#      query widened past the release-pipeline group have to wade through hundreds of dead groups.
#
# WHAT KEEPS IT FROM DELETING SOMETHING A RUNNING BUILD NEEDS - three independent guards, because
# an unattended destroy has no one watching it:
#
#   - The name must match <kind>-<YYMMDD>-<rand4>. "test" and "production" cannot match, and
#     teardown-ephemeral-env.sh re-checks this itself before touching anything.
#   - A .tflock object anywhere under the environment's state prefix means Terraform holds the lock
#     right now (backend.hcl sets use_lockfile = true). Skipped outright, whatever its age.
#   - Nothing is touched until every object under its prefix is older than --max-age-hours
#     (default 12). A release build writes state at apply and again at destroy, and GitHub caps a
#     job at 6 hours, so 12 is comfortably beyond any run that is still going.
#
# Usage: ./sweep-stale-envs.sh [--destroy] [--max-age-hours N] [--include-named-envs]
set -euo pipefail

mode="report"
max_age_hours=12
include_named_envs=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --destroy) mode="destroy"; shift ;;
    --max-age-hours) max_age_hours="${2:?--max-age-hours needs a value}"; shift 2 ;;
    --include-named-envs) include_named_envs=1; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ ! "${max_age_hours}" =~ ^[0-9]+$ ]]; then
  echo "--max-age-hours must be a whole number of hours, got '${max_age_hours}'." >&2
  exit 1
fi

# Same no-cd-here reasoning as cleanup-stale-envs.sh and teardown-ephemeral-env.sh.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
teardown_script="${script_dir}/teardown-ephemeral-env.sh"
if [[ ! -f "${teardown_script}" ]]; then
  echo "Expected to find ${teardown_script} alongside this script." >&2
  exit 1
fi

# The convention every ephemeral script here shares - see create-ephemeral-env.sh's usage comment.
ephemeral_re='^[a-z][a-z0-9-]{0,7}-[0-9]{6}-[a-z0-9]{4}$'

account_id="$(aws sts get-caller-identity --query Account --output text)"
if [[ -z "${account_id}" || "${account_id}" == "None" ]]; then
  echo "Failed to determine the AWS account id (aws sts get-caller-identity). Check your AWS credentials." >&2
  exit 1
fi
bucket="remote-state-${account_id}"
now_epoch="$(date -u +%s)"
cutoff_epoch=$(( now_epoch - max_age_hours * 3600 ))

echo "Sweep mode: ${mode}   |   stale after: ${max_age_hours}h   |   state bucket: s3://${bucket}"
echo ""

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

# ---------------------------------------------------------------------------
# Ephemeral environments
# ---------------------------------------------------------------------------

aws s3api list-objects-v2 --bucket "${bucket}" \
  --query 'Contents[].[Key,LastModified]' --output text > "${workdir}/keys.txt"

mapfile -t envs < <(cut -f1 "${workdir}/keys.txt" | cut -d/ -f1 | grep -E "${ephemeral_re}" | sort -u)

live_envs=()      # real resources, need a teardown
empty_envs=()     # state already destroyed, only the S3 object is left
locked_envs=()    # Terraform holds the lock right now
young_envs=()     # touched too recently to be sure it is not in use

for env in "${envs[@]+"${envs[@]}"}"; do
  grep -P "^\Q${env}\E/" "${workdir}/keys.txt" > "${workdir}/env-keys.txt" || true

  if cut -f1 "${workdir}/env-keys.txt" | grep -q '\.tflock$'; then
    locked_envs+=("${env}")
    continue
  fi

  newest_epoch=0
  while IFS=$'\t' read -r _key last_modified; do
    [[ -z "${last_modified}" ]] && continue
    epoch="$(date -u -d "${last_modified}" +%s)"
    (( epoch > newest_epoch )) && newest_epoch="${epoch}"
  done < "${workdir}/env-keys.txt"

  if (( newest_epoch > cutoff_epoch )); then
    age_h=$(( (now_epoch - newest_epoch) / 3600 ))
    young_envs+=("${env} (last written ${age_h}h ago)")
    continue
  fi

  # An empty state file still lists in S3, so size and presence prove nothing about whether
  # anything is actually deployed. Read the state and count its resources - that is the only
  # answer that distinguishes "stranded, costing money" from "already gone, just untidy".
  resource_count=0
  while IFS= read -r key; do
    [[ "${key}" == *.tfstate ]] || continue
    if aws s3api get-object --bucket "${bucket}" --key "${key}" "${workdir}/state.json" >/dev/null 2>&1; then
      n="$(jq '(.resources // []) | length' "${workdir}/state.json" 2>/dev/null || echo 0)"
      resource_count=$(( resource_count + n ))
    fi
  done < <(cut -f1 "${workdir}/env-keys.txt")

  if (( resource_count > 0 )); then
    live_envs+=("${env} (${resource_count} resources in state)")
  else
    empty_envs+=("${env}")
  fi
done

# ---------------------------------------------------------------------------
# Orphaned Lambda log groups
# ---------------------------------------------------------------------------

aws lambda list-functions --query 'Functions[].FunctionName' --output text \
  | tr '\t' '\n' | sed '/^$/d' | sort > "${workdir}/functions.txt"

aws logs describe-log-groups --log-group-name-prefix /aws/lambda/ \
  --query 'logGroups[].[logGroupName,creationTime]' --output text > "${workdir}/loggroups.txt"

orphan_ephemeral=()   # belonged to an ephemeral environment - unambiguous garbage
orphan_named=()       # belonged to a retired production/test Lambda - has history, decide separately
orphan_unknown=()     # not recognisably this project's - reported, never deleted

# creationTime is epoch milliseconds. A group younger than an hour may belong to a function
# Terraform is creating right now (Lambda auto-creates the group on first invocation, and
# SnapStart's version publish invokes init - see the design's step 12), so leave it alone.
young_group_cutoff_ms=$(( (now_epoch - 3600) * 1000 ))

while IFS=$'\t' read -r group_name created_ms; do
  [[ -z "${group_name}" ]] && continue
  fn="${group_name#/aws/lambda/}"
  grep -qxF "${fn}" "${workdir}/functions.txt" && continue
  (( created_ms > young_group_cutoff_ms )) && continue

  # "mootmaker" and "room-booking" (its name before the rename) are this project's; anything else
  # in the account belongs to something else and is reported rather than swept.
  if [[ "${fn}" =~ ^([a-z][a-z0-9-]{0,7}-[0-9]{6}-[a-z0-9]{4})- ]] \
     && [[ "${fn}" == *-mootmaker-* || "${fn}" == *-room-booking-* ]]; then
    orphan_ephemeral+=("${group_name}")
  elif [[ "${fn}" == production-mootmaker-* || "${fn}" == test-mootmaker-* \
       || "${fn}" == production-room-booking-* || "${fn}" == test-room-booking-* \
       || "${fn}" == room-booking-* ]]; then
    orphan_named+=("${group_name}")
  else
    orphan_unknown+=("${group_name}")
  fi
done < "${workdir}/loggroups.txt"

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

section() { echo ""; echo "## $1"; echo ""; }
listing() {
  if [[ "$#" -eq 0 ]]; then echo "  (none)"; else printf '  - %s\n' "$@"; fi
}

section "Ephemeral environments with live infrastructure"
echo "  Stranded by an interrupted run and still costing money. These need a real teardown."
listing "${live_envs[@]+"${live_envs[@]}"}"

section "Ephemeral environments already destroyed, state object left behind"
echo "  Nothing is deployed. Only the empty S3 state object remains."
listing "${empty_envs[@]+"${empty_envs[@]}"}"

section "Orphaned Lambda log groups from ephemeral environments"
echo "  The function is gone; terraform destroy does not remove the group Lambda auto-created."
listing "${orphan_ephemeral[@]+"${orphan_ephemeral[@]}"}"

section "Orphaned Lambda log groups from retired production/test functions"
echo "  Also orphaned, but these hold real history from functions that were consolidated away."
echo "  Not swept unless --include-named-envs is given."
listing "${orphan_named[@]+"${orphan_named[@]}"}"

section "Skipped"
echo "  In use (Terraform holds the lock):"
listing "${locked_envs[@]+"${locked_envs[@]}"}"
echo "  Written too recently to be sure (younger than ${max_age_hours}h):"
listing "${young_envs[@]+"${young_envs[@]}"}"
echo "  Log groups not recognisable as this project's - reported, never deleted:"
listing "${orphan_unknown[@]+"${orphan_unknown[@]}"}"

echo ""
echo "Summary: ${#live_envs[@]} stranded, ${#empty_envs[@]} leftover state objects, ${#orphan_ephemeral[@]} ephemeral log groups, ${#orphan_named[@]} retired-function log groups."

if [[ "${mode}" == "report" ]]; then
  echo ""
  echo "Report-only. Nothing was changed. Re-run with --destroy to act on the first three sections."
  exit 0
fi

# ---------------------------------------------------------------------------
# Destroy
# ---------------------------------------------------------------------------

echo ""
echo "=== --destroy given: acting ==="
failures=0

for entry in "${live_envs[@]+"${live_envs[@]}"}"; do
  env="${entry%% *}"
  echo "--- Tearing down '${env}' ---"
  # --yes because there is no stdin here to answer undeploy.sh's prompts. The name check inside
  # teardown-ephemeral-env.sh runs first and independently of anything decided above.
  if ! "${teardown_script}" "${env}" --yes; then
    echo "Teardown of '${env}' FAILED - left in place for investigation." >&2
    failures=$(( failures + 1 ))
  fi
done

for env in "${empty_envs[@]+"${empty_envs[@]}"}"; do
  echo "--- Removing leftover state objects for '${env}' ---"
  if ! aws s3 rm "s3://${bucket}/${env}/" --recursive; then
    echo "Failed to remove state objects for '${env}'." >&2
    failures=$(( failures + 1 ))
  fi
done

groups_to_delete=("${orphan_ephemeral[@]+"${orphan_ephemeral[@]}"}")
if [[ "${include_named_envs}" == "1" ]]; then
  groups_to_delete+=("${orphan_named[@]+"${orphan_named[@]}"}")
fi
for group in "${groups_to_delete[@]+"${groups_to_delete[@]}"}"; do
  echo "--- Deleting log group ${group} ---"
  if ! aws logs delete-log-group --log-group-name "${group}"; then
    echo "Failed to delete log group ${group}." >&2
    failures=$(( failures + 1 ))
  fi
done

if (( failures > 0 )); then
  echo ""
  echo "Sweep finished with ${failures} failure(s)." >&2
  exit 1
fi

echo ""
echo "Sweep finished cleanly."
