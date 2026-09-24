#!/usr/bin/env bash
# Tears down one specific, already-known ephemeral environment.
#
# DISCOVERS what is deployed by listing the environment's own Terraform state prefix in S3, rather
# than iterating a hardcoded list of components. That is the fix for a real bug: the previous
# version knew only about mootmaker-webapp and mootmaker-api, so tearing down an environment that
# also had demo tooling deployed removed two components, left the others' state orphaned in S3, and
# reported success throughout. A component nobody remembered is now still torn down - and one this
# script does not recognise stops it, loudly, instead of being silently skipped.
#
# Refuses to run against anything that doesn't look like a recognized <kind>-<YYMMDD>-<rand4>
# ephemeral environment name - a hard safety rail (a typo must never be able to reach
# "production"), not just a UX nicety. By default each undeploy.sh then prompts for its own
# interactive confirmation (no -auto-approve) before destroying anything.
#
# --yes passes through to each undeploy.sh, replacing those prompts with -auto-approve, for
# automation that has no stdin to answer them: the release pipeline's ephemeral acceptance
# environments and the scheduled ephemeral sweep (mootmaker/designs/archive/ci-cd-pipeline.md Rollout
# steps 6 and 11). The name check above still applies and still runs first, so --yes can only ever
# accelerate a teardown this script was already willing to perform - and each undeploy.sh refuses
# "production"/"test" under --yes independently of that.
#
# Usage: ./teardown-ephemeral-env.sh <name> [--yes]
set -euo pipefail

# No `cd "$(dirname "$0")"` here - it breaks when invoked via a relative path with a directory
# component (e.g. `./mootmaker-ephemeral-envs/teardown-ephemeral-env.sh` from a parent dir), colliding
# with the BASH_SOURCE-based cd further below - see mootmaker-webapp/e2e/run.sh's fuller comment
# on the same bug, found and fixed there 2026-08-22.

assume_yes=0
args=()
for arg in "$@"; do
  if [[ "${arg}" == "--yes" ]]; then
    assume_yes=1
  else
    args+=("${arg}")
  fi
done
set -- "${args[@]+"${args[@]}"}"

name="${1:-}"
if [[ -z "${name}" ]]; then
  echo "Usage: ./teardown-ephemeral-env.sh <name> [--yes]   (e.g. claude-260815-x7q2)" >&2
  exit 1
fi

# Must look exactly like <kind>-<YYMMDD>-<rand4>, where kind is 1-8 lowercase
# letters/digits/hyphens starting with a letter (e.g. "claude", "web-e2e",
# "web-acc" - see create-ephemeral-env.sh's own usage comment for the
# convention, and mootmaker/docs/reference/testing-strategy.md#environments for the
# day-only-timestamp reasoning). Deliberately strict on shape, not on which
# specific kind values exist: this script's whole job is to be safe to point
# at an arbitrary string without risking "production", not to be
# the source of truth for which kinds are in use.
if [[ ! "${name}" =~ ^[a-z][a-z0-9-]{0,7}-[0-9]{6}-[a-z0-9]{4}$ ]]; then
  echo "'${name}' doesn't look like a <kind>-<YYMMDD>-<rand4> ephemeral environment name (expected e.g. claude-260815-x7q2 or web-e2e-260815-x7q2)." >&2
  echo "Refusing to undeploy - this script only ever touches ephemeral environments, never 'test' or 'production'." >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Every component this project knows how to undeploy: state-key name -> checkout directory. The
# state key under <environment>/ is the repository name, which is exactly why collapsing the demo
# tooling into a single mootmaker-demo-data component made this table tractable - see
# mootmaker/designs/archive/demo-data-component.md.
declare -A component_dirs=(
  [mootmaker-webapp]="${script_dir}/../mootmaker-webapp"
  [mootmaker-api]="${script_dir}/../mootmaker-api"
  [mootmaker-demo-data]="${script_dir}/../mootmaker-demo-data"
)

# Undeploy order matters: consumers before the API they read, so nothing is left pointing at a
# half-destroyed environment. Anything discovered that isn't in this list is an error, not a
# silent skip.
teardown_order=(mootmaker-webapp mootmaker-demo-data mootmaker-api)

account_id="$(aws sts get-caller-identity --query Account --output text)"
# Matches the naming convention documented in mootmaker-bootstrap-terraform's README:
# "remote-state-<aws-account-id>" - same derivation cleanup-stale-envs.sh and
# list-ephemeral-envs.sh use.
state_bucket="remote-state-${account_id}"

echo "Discovering components deployed to '${name}' from s3://${state_bucket}/${name}/..." >&2
mapfile -t discovered < <(
  aws s3api list-objects-v2 --bucket "${state_bucket}" --prefix "${name}/" \
    --query 'Contents[].Key' --output text 2>/dev/null |
    tr '\t' '\n' | sed -n "s|^${name}/\(.*\)/terraform.tfstate$|\1|p" | sort -u
)

if [[ "${#discovered[@]}" -eq 0 ]]; then
  echo "No Terraform state found for '${name}' - nothing to tear down." >&2
  echo "(If you expected resources here, check the name: state lives at s3://${state_bucket}/${name}/<component>/terraform.tfstate.)" >&2
  exit 0
fi

echo "Found: ${discovered[*]}" >&2

# Refuse rather than guess. An unrecognised component means real infrastructure this script cannot
# destroy; carrying on would delete the state objects it does know about and report success while
# leaving that component running with nothing tracking it - the exact failure being fixed here.
unknown=()
for component in "${discovered[@]}"; do
  if [[ -z "${component_dirs[${component}]:-}" ]]; then
    unknown+=("${component}")
  fi
done
if [[ "${#unknown[@]}" -gt 0 ]]; then
  echo "Refusing to tear down '${name}': found state for component(s) this script doesn't know how to undeploy: ${unknown[*]}" >&2
  echo "Undeploy them by hand first (each project's own undeploy.sh), or add them to component_dirs in this script." >&2
  exit 1
fi

for component in "${teardown_order[@]}"; do
  # shellcheck disable=SC2076
  if [[ ! " ${discovered[*]} " =~ " ${component} " ]]; then
    continue
  fi
  dir="${component_dirs[${component}]}"
  if [[ ! -f "${dir}/undeploy.sh" ]]; then
    echo "Expected to find the ${component} checkout at ${dir} (as a sibling of this directory)." >&2
    exit 1
  fi
  echo "=== Undeploying ${component} from '${name}' ===" >&2
  undeploy_args=("${name}")
  if [[ "${assume_yes}" == "1" ]]; then
    undeploy_args+=(--yes)
  fi
  "${dir}/undeploy.sh" "${undeploy_args[@]}"
done

# terraform destroy empties a state file's contents but doesn't delete the S3 object itself, so
# without this, a fully-torn-down environment keeps showing up in cleanup-stale-envs.sh's
# discovery (which lists state-bucket keys, not their contents) forever. Only the objects this
# script itself just emptied are removed.
echo "Removing this environment's now-empty state files from s3://${state_bucket}..." >&2
removal_failed=""
for component in "${discovered[@]}"; do
  aws s3 rm "s3://${state_bucket}/${name}/${component}/terraform.tfstate" >&2 || removal_failed="true"
done
if [[ -n "${removal_failed}" ]]; then
  echo "Warning: failed to remove one or more state files for '${name}' from s3://${state_bucket} - it may still show up in cleanup-stale-envs.sh's discovery. The environment itself was torn down successfully regardless." >&2
fi

# An environment is only "gone" when its state prefix is empty. Asserting that is the point: the
# previous version trusted that the right scripts had been called, which is precisely how it
# reported success while leaving state behind.
remaining="$(aws s3api list-objects-v2 --bucket "${state_bucket}" --prefix "${name}/" \
  --query 'length(Contents)' --output text 2>/dev/null || echo "None")"
if [[ "${remaining}" != "None" && "${remaining}" != "0" ]]; then
  echo "Warning: s3://${state_bucket}/${name}/ still contains ${remaining} object(s) after teardown:" >&2
  aws s3 ls "s3://${state_bucket}/${name}/" --recursive >&2 || true
  echo "'${name}' is NOT fully torn down. Investigate before assuming it is gone." >&2
  exit 1
fi

echo "Ephemeral environment '${name}' torn down; its state prefix is empty." >&2
