#!/usr/bin/env bash
# Batch sweep for ephemeral environments left behind by an interrupted
# session or a failed run. Discovers every recognized <kind>-<YYMMDD>-<rand4>
# environment (e.g. "claude-260815-x7q2", "web-e2e-260819-a1b2" - see
# create-ephemeral-env.sh's usage comment for the naming convention) across
# ALL projects by listing the shared Terraform state bucket's object keys
# and grouping by the first path segment of
# <environment>/<project-name>/terraform.tfstate - no separate environment
# registry needed (see mootmaker-test-infra/testing-strategy.md
# #ephemeral-environment-scripts and mootmaker-bootstrap-terraform's README
# for how the shared state bucket/key layout works).
#
# Lists everything it finds, then asks for interactive confirmation before
# tearing down EACH one individually, matching undeploy.sh's own
# always-interactive, no-auto-approve safety pattern. Deliberately no
# --yes/--force flag and no age-threshold auto-selection: explicit
# per-environment confirmation is the intended safety behaviour here, not a
# placeholder for something more automatic. Runnable by Geoff directly, or
# by Claude.
#
# Usage: ./cleanup-stale-envs.sh
set -euo pipefail

# No `cd "$(dirname "$0")"` here - it breaks when invoked via a relative path with a directory
# component (e.g. `./mootmaker-test-infra/cleanup-stale-envs.sh` from a parent dir), colliding
# with the BASH_SOURCE-based cd below - see mootmaker-webapp/e2e/run.sh's fuller comment on the
# same bug, found and fixed there 2026-08-22.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
teardown_script="${script_dir}/teardown-ephemeral-env.sh"

if [[ ! -f "${teardown_script}" ]]; then
  echo "Expected to find ${teardown_script} alongside this script." >&2
  exit 1
fi

echo "Looking up the shared Terraform state bucket..." >&2
account_id="$(aws sts get-caller-identity --query Account --output text)"
if [[ -z "${account_id}" ]]; then
  echo "Failed to determine the AWS account id (aws sts get-caller-identity). Check your AWS credentials." >&2
  exit 1
fi
# Matches the naming convention documented in mootmaker-bootstrap-terraform's
# README: "remote-state-<aws-account-id>".
bucket="remote-state-${account_id}"

echo "Scanning s3://${bucket} for ephemeral environments..." >&2
keys_json="$(aws s3api list-objects-v2 --bucket "${bucket}" --query 'Contents[].Key' --output json 2>/dev/null || echo '[]')"
if [[ -z "${keys_json}" || "${keys_json}" == "null" ]]; then
  keys_json='[]'
fi

# Group by the first path segment (the environment name), keep only names
# matching the <kind>-<YYMMDD>-<rand4> convention, dedupe.
mapfile -t envs < <(
  echo "${keys_json}" | jq -r '.[]' \
    | cut -d/ -f1 \
    | grep -E '^[a-z][a-z0-9-]{0,7}-[0-9]{6}-[a-z0-9]{4}$' \
    | sort -u
)

if [[ "${#envs[@]}" -eq 0 ]]; then
  echo "No stale ephemeral environments found in s3://${bucket}."
  exit 0
fi

echo ""
echo "Found ${#envs[@]} ephemeral environment(s) in s3://${bucket}:"
for env in "${envs[@]}"; do
  echo "  - ${env}"
done
echo ""

for env in "${envs[@]}"; do
  read -r -p "Tear down '${env}'? [y/N] " confirm
  case "${confirm}" in
    y|Y|yes|YES|Yes)
      "${teardown_script}" "${env}"
      ;;
    *)
      echo "Skipping '${env}'."
      ;;
  esac
done

echo "cleanup-stale-envs.sh done."
