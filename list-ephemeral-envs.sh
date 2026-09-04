#!/usr/bin/env bash
# Read-only report on every ephemeral environment discovered in the shared Terraform state bucket:
# for each <environment>/<project>/terraform.tfstate object, downloads it and counts the resources
# actually tracked inside. A count of 0 means that project's real AWS resources are already gone
# (a successful `terraform destroy` already ran) and the state file itself is just a leftover
# object with nothing left to destroy - safe to delete directly, no teardown needed.
#
# For anything with a nonzero count (mootmaker-api/mootmaker-webapp only - see "Known project
# layouts" below), also runs `terraform plan -refresh-only -detailed-exitcode` against it: a
# read-only operation that refreshes Terraform's view of the *actual* AWS resources and compares
# them to what's recorded in state, without proposing or applying any change and without persisting
# the refresh back to the remote state file (only `terraform apply -refresh-only` would do that).
#
# IMPORTANT: a nonzero `-detailed-exitcode` (2) from a refresh-only plan does NOT by itself mean
# resources were removed - verified against a real, freshly-deployed environment while building
# this script: 12 of its resources showed as "changed" (ACM certificate finishing async
# validation, `tags = {}`/`layers = []` provider-schema cosmetic defaults, a Cognito pool's
# genuinely-changing estimated_number_of_users) with zero actually missing. Terraform's own
# refresh-only output distinguishes the two cases textually - "# X has changed" (attributes differ,
# resource still exists) versus "# X has been deleted" (refresh couldn't find it in AWS at all) -
# so this script greps specifically for the latter rather than treating any nonzero exit code as
# "gone". See "Known false-positive risk" below for the one thing this still can't distinguish.
#
# Complements cleanup-stale-envs.sh rather than replacing it: this only lists and classifies, it
# never destroys, deletes, or applies anything. Use this first to see what you're actually dealing
# with, then use teardown-ephemeral-env.sh/cleanup-stale-envs.sh for anything that still needs a
# real teardown (which also removes their state files once torn down, see
# teardown-ephemeral-env.sh's own cleanup step).
#
# Usage: ./list-ephemeral-envs.sh
set -euo pipefail

# No `cd "$(dirname "$0")"` here - it breaks when invoked via a relative path with a directory
# component (e.g. `./mootmaker-ephemeral-envs/list-ephemeral-envs.sh` from a parent dir), colliding
# with the BASH_SOURCE-based cd below - see mootmaker-webapp/e2e/run.sh's fuller comment on the
# same bug, found and fixed there 2026-08-22.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Looking up the shared Terraform state bucket..." >&2
account_id="$(aws sts get-caller-identity --query Account --output text)"
if [[ -z "${account_id}" ]]; then
  echo "Failed to determine the AWS account id (aws sts get-caller-identity). Check your AWS credentials." >&2
  exit 1
fi
# Matches the naming convention documented in mootmaker-bootstrap-terraform's README:
# "remote-state-<aws-account-id>" - same derivation cleanup-stale-envs.sh uses.
bucket="remote-state-${account_id}"

echo "Scanning s3://${bucket} for ephemeral environment state files..." >&2
objects_json="$(aws s3api list-objects-v2 --bucket "${bucket}" \
  --query 'Contents[].{Key:Key,LastModified:LastModified}' --output json 2>/dev/null || echo '[]')"
if [[ -z "${objects_json}" || "${objects_json}" == "null" ]]; then
  objects_json='[]'
fi

# Only <kind>-<YYMMDD>-<rand4>/<project>/terraform.tfstate keys - same shape
# teardown-ephemeral-env.sh/cleanup-stale-envs.sh recognize (see create-ephemeral-env.sh's usage
# comment for the naming convention), so this never lists persistent infrastructure that happens
# to share the same bucket (e.g. mootmaker-email-testing's own mootmaker-e2e-email/, mootmaker-domain's
# domain/, or test/production/bootstrap) - and never runs a plan against test/production either,
# since it's structurally impossible for this filter to match either name.
mapfile -t rows < <(
  echo "${objects_json}" | jq -r '
    .[]
    | select(.Key | test("^[a-z][a-z0-9-]{0,7}-[0-9]{6}-[a-z0-9]{4}/.+/terraform\\.tfstate$"))
    | "\(.Key)\t\(.LastModified)"
  '
)

if [[ "${#rows[@]}" -eq 0 ]]; then
  echo "No ephemeral environment state files found in s3://${bucket}."
  exit 0
fi

# Known project layouts: state-key project name -> sibling checkout with a deploy/terraform/ this
# script knows how to plan against (same -var="environment=..." shape every deploy.sh/undeploy.sh
# already uses - see mootmaker-api/mootmaker-webapp's own deploy.sh). Anything else (e.g. an ad hoc
# mootmaker-demo-data/*/deploy.sh or mootmaker-admin-tools/*/deploy.sh run, which nests under that project rather than its own top-level
# checkout, and has its own separate variables this script doesn't know) is deliberately not
# guessed at - the resource count from state alone is still shown, just not cross-checked against
# real AWS.
declare -A project_dirs=(
  [mootmaker-api]="${script_dir}/../mootmaker-api"
  [mootmaker-webapp]="${script_dir}/../mootmaker-webapp"
)

# Per-row detail (missing-resource lists, failure messages) is written to files here rather than
# accumulated in a shell array - check_against_aws below is invoked via command substitution
# ("$(check_against_aws ...)") to capture its one-line status, and command substitution always
# forks a subshell; any array appended to *inside* that subshell would vanish once the subshell
# exits; a file survives it.
detail_dir="$(mktemp -d)"
trap 'rm -rf "${detail_dir}"' EXIT

# check_against_aws KEY ENV PROJECT
# Prints exactly one of: matches | present (drift) | MISSING | init failed | plan failed | skipped
# to stdout. For MISSING, writes the specific resource addresses refresh couldn't find in AWS to
# "${detail_dir}/${env}__${project}.missing"; for init/plan failures, writes the error to
# "${detail_dir}/${env}__${project}.error".
check_against_aws() {
  local key="$1" env="$2" project="$3"
  local project_dir="${project_dirs[${project}]:-}"

  if [[ -z "${project_dir}" || ! -d "${project_dir}/deploy/terraform" ]]; then
    echo "skipped"
    return
  fi

  # A stable (not per-run-random) TF_DATA_DIR so the provider plugin cache is reused across
  # environments/projects and across repeated runs of this script, rather than redownloading the
  # AWS provider every time - matches ".terraform-*/" already in every project's .gitignore.
  # -reconfigure is required because this same directory gets pointed at a different backend `key`
  # on every call (a different environment/project each time); without it, Terraform would try to
  # interactively prompt about migrating state between backends, which would hang this script.
  local tf_data_dir="${project_dir}/deploy/terraform/.terraform-verify"
  local init_log="${detail_dir}/${env}__${project}.error"
  if ! TF_DATA_DIR="${tf_data_dir}" terraform -chdir="${project_dir}/deploy/terraform" init \
      -reconfigure -backend-config=backend.hcl -backend-config="key=${key}" -input=false \
      >"${init_log}" 2>&1; then
    echo "init failed"
    return
  fi
  rm -f "${init_log}"

  # Always redirected fully to a file, never piped into anything that could close early (e.g.
  # `head`) and SIGPIPE terraform mid-operation - doing that once while building this script left
  # a stale S3 state lock behind (terraform never reached its own unlock/cleanup step), needing a
  # manual `terraform force-unlock` to clear. A real command failure is caught below via the exit
  # code instead, not by watching the pipe.
  local plan_log="${detail_dir}/${env}__${project}.plan"
  local plan_exit=0
  TF_DATA_DIR="${tf_data_dir}" terraform -chdir="${project_dir}/deploy/terraform" \
    plan -refresh-only -detailed-exitcode -var="environment=${env}" -input=false -no-color \
    >"${plan_log}" 2>&1 || plan_exit=$?

  case "${plan_exit}" in
    0)
      rm -f "${plan_log}"
      echo "matches"
      ;;
    2)
      # Terraform's own refresh-only output distinguishes these textually - see this script's
      # top-of-file comment for why only "has been deleted" counts as actually missing.
      mapfile -t missing < <(grep -oP '(?<=^  # ).*(?= has been deleted$)' "${plan_log}" || true)
      if [[ "${#missing[@]}" -gt 0 ]]; then
        printf '%s\n' "${missing[@]}" > "${detail_dir}/${env}__${project}.missing"
        rm -f "${plan_log}"
        echo "MISSING"
      else
        rm -f "${plan_log}"
        echo "present (drift)"
      fi
      ;;
    *)
      mv "${plan_log}" "${init_log}" 2>/dev/null || true
      echo "plan failed"
      ;;
  esac
}

# Read every state file's resource count UP FRONT, in parallel, rather than one at a time inside
# the display loop below. This is what made the script take over three minutes (#3): with ~105
# state objects and each `aws s3 cp` costing ~1.9s almost entirely in AWS CLI process startup
# (Python import time, not network - measured, not assumed), the serial version spent ~200s doing
# nothing but launching processes. The terraform refresh was never the cause; it is skipped
# entirely for empty state, and by 2026-09 almost every leftover state file is empty.
#
# -P 10 rather than unbounded: each job is a separate CLI process, and hundreds at once would
# trade the startup cost for memory pressure and S3 throttling. Ten is enough that startup stops
# being the bottleneck.
echo "Reading ${#rows[@]} state file(s) in parallel..." >&2
counts_dir="${detail_dir}/counts"
mkdir -p "${counts_dir}"
printf '%s\n' "${rows[@]}" | cut -d$'\t' -f1 | xargs -P 10 -I{} bash -c '
  key="$1"
  # The key contains slashes; flatten them so it can name a file.
  out="$2/${key//\//__}"
  aws s3 cp "s3://$3/${key}" - 2>/dev/null | jq ".resources | length" 2>/dev/null > "${out}" || true
  # An unreadable or non-JSON state leaves an empty file, which reads back as "?" below - the
  # same outcome the serial version produced via its `|| echo "?"`.
' _ {} "${counts_dir}" "${bucket}"

echo ""
printf '%-24s %-32s %-9s %-16s %s\n' "ENVIRONMENT" "PROJECT" "RESOURCES" "AWS CHECK" "LAST MODIFIED"
printf '%-24s %-32s %-9s %-16s %s\n' "-----------" "-------" "---------" "---------" "-------------"

any_empty="false"
for row in "${rows[@]}"; do
  key="${row%%$'\t'*}"
  last_modified="${row#*$'\t'}"
  env="${key%%/*}"
  project="${key#*/}"
  project="${project%/terraform.tfstate}"

  resource_count="$(cat "${counts_dir}/${key//\//__}" 2>/dev/null || true)"
  [[ -z "${resource_count}" ]] && resource_count="?"

  if [[ "${resource_count}" == "0" ]]; then
    label="0 (empty)"
    aws_check="n/a"
    any_empty="true"
  elif [[ "${resource_count}" == "?" ]]; then
    label="? (unreadable)"
    aws_check="n/a"
  else
    label="${resource_count}"
    echo "Checking ${env}/${project} against real AWS (terraform plan -refresh-only)..." >&2
    aws_check="$(check_against_aws "${key}" "${env}" "${project}")"
  fi

  printf '%-24s %-32s %-9s %-16s %s\n' "${env}" "${project}" "${label}" "${aws_check}" "${last_modified}"
done

shopt -s nullglob
missing_files=("${detail_dir}"/*.missing)
error_files=("${detail_dir}"/*.error)
shopt -u nullglob

if [[ "${#missing_files[@]}" -gt 0 ]]; then
  echo ""
  echo "=== MISSING: resources state still tracks but AWS no longer has ===" >&2
  for f in "${missing_files[@]}"; do
    base="$(basename "${f}" .missing)"
    echo "${base%%__*} / ${base#*__}:"
    sed 's/^/  - /' "${f}"
  done
fi

if [[ "${#error_files[@]}" -gt 0 ]]; then
  echo ""
  echo "=== AWS check failed for these (couldn't determine whether resources still exist) ===" >&2
  for f in "${error_files[@]}"; do
    base="$(basename "${f}" .error)"
    echo "--- ${base%%__*} / ${base#*__} ---"
    tail -15 "${f}"
    echo ""
  done
fi

if [[ "${any_empty}" == "true" ]]; then
  echo ""
  echo "Environments/projects marked 0 (empty) above have nothing left to destroy - their state" >&2
  echo "file is a leftover from an already-completed teardown (predating teardown-ephemeral-env.sh's" >&2
  echo "own state-file cleanup, added 2026-08-19 - see testing-strategy.md#naming-convention). Safe" >&2
  echo "to delete directly, e.g.:" >&2
  echo "  aws s3 rm s3://${bucket}/<environment>/<project>/terraform.tfstate" >&2
fi
echo "Anything with a nonzero resource count still has state claiming real AWS infrastructure - see" >&2
echo "the AWS CHECK column: \"matches\"/\"present (drift)\" both mean it's genuinely still deployed" >&2
echo "(drift alone - tags, ACM validation finishing, etc. - isn't a sign anything's missing; see" >&2
echo "this script's own top-of-file comment); \"MISSING\" means specific resources are confirmed" >&2
echo "gone from AWS even though state doesn't know it yet. Either way, a real teardown via" >&2
echo "./teardown-ephemeral-env.sh <environment> or ./cleanup-stale-envs.sh is the correct next step" >&2
echo "for anything still showing real resources - Terraform reconciles MISSING ones as part of a" >&2
echo "normal destroy." >&2
