#!/usr/bin/env bash
# Tears down one specific, already-known ephemeral environment: calls
# undeploy.sh for mootmaker-webapp then mootmaker-api (sibling checkouts).
# This is what create-ephemeral-env.sh's failure trap points at, and what
# Claude's commit-time cleanup prompt (see mootmaker/testing-strategy.md
# #ephemeral-environment-lifecycle) uses once the user confirms.
#
# Refuses to run against anything that doesn't look like a recognized
# <kind>-<YYMMDD>-<rand4> ephemeral environment name - this is a hard safety rail (a typo must never
# be able to reach "test" or "production"), not just a UX nicety. Each
# undeploy.sh still prompts for its own interactive confirmation (no
# -auto-approve) before destroying anything.
#
# Usage: ./teardown-ephemeral-env.sh <name>
set -euo pipefail
cd "$(dirname "$0")"

name="${1:-}"
if [[ -z "${name}" ]]; then
  echo "Usage: ./teardown-ephemeral-env.sh <name>   (e.g. claude-260815-x7q2)" >&2
  exit 1
fi

# Must look exactly like <kind>-<YYMMDD>-<rand4>, where kind is 1-8 lowercase
# letters/digits/hyphens starting with a letter (e.g. "claude", "web-e2e",
# "web-acc" - see create-ephemeral-env.sh's own usage comment for the
# convention, and mootmaker/testing-strategy.md#environments for the
# day-only-timestamp reasoning). Deliberately strict on shape, not on which
# specific kind values exist: this script's whole job is to be safe to point
# at an arbitrary string without risking "test" or "production", not to be
# the source of truth for which kinds are in use.
if [[ ! "${name}" =~ ^[a-z][a-z0-9-]{0,7}-[0-9]{6}-[a-z0-9]{4}$ ]]; then
  echo "'${name}' doesn't look like a <kind>-<YYMMDD>-<rand4> ephemeral environment name (expected e.g. claude-260815-x7q2 or web-e2e-260815-x7q2)." >&2
  echo "Refusing to undeploy - this script only ever touches ephemeral environments, never 'test' or 'production'." >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
api_dir="${script_dir}/../mootmaker-api"
webapp_dir="${script_dir}/../mootmaker-webapp"

if [[ ! -f "${api_dir}/undeploy.sh" ]]; then
  echo "Expected to find the mootmaker-api checkout at ${api_dir} (as a sibling of this directory)." >&2
  exit 1
fi
if [[ ! -f "${webapp_dir}/undeploy.sh" ]]; then
  echo "Expected to find the mootmaker-webapp checkout at ${webapp_dir} (as a sibling of this directory)." >&2
  exit 1
fi

echo "Tearing down ephemeral environment '${name}'..." >&2

"${webapp_dir}/undeploy.sh" "${name}"
"${api_dir}/undeploy.sh" "${name}"

echo "Ephemeral environment '${name}' torn down." >&2

# terraform destroy empties a state file's contents but doesn't delete the S3 object itself, so
# without this, a fully-torn-down environment keeps showing up in cleanup-stale-envs.sh's
# discovery (which lists state-bucket keys, not their contents) forever - see
# testing-strategy.md's "Testing notes" for the behaviour this replaces. Only the two state
# objects this script itself is responsible for (the ones the two undeploy.sh calls above just
# emptied) are removed - never anything else under this environment's prefix, in case some other
# project's state also happens to live there (e.g. an ad hoc mootmaker-tools/*/deploy.sh run
# against this same environment name) that this script has no knowledge of and didn't just
# destroy; deleting that state object without having destroyed its resources first would orphan
# real infrastructure with nothing left to track it. A best-effort step, not a hard failure: the
# actual teardown above already succeeded by this point, so a transient S3 error here shouldn't
# make this script report failure for work it already finished.
account_id="$(aws sts get-caller-identity --query Account --output text)"
# Matches the naming convention documented in mootmaker-bootstrap-terraform's README:
# "remote-state-<aws-account-id>" - same derivation cleanup-stale-envs.sh uses.
state_bucket="remote-state-${account_id}"
echo "Removing this environment's now-empty state files from s3://${state_bucket}..." >&2
if ! aws s3 rm "s3://${state_bucket}/${name}/mootmaker-webapp/terraform.tfstate" >&2 ||
   ! aws s3 rm "s3://${state_bucket}/${name}/mootmaker-api/terraform.tfstate" >&2; then
  echo "Warning: failed to remove one or more state files for '${name}' from s3://${state_bucket} - it may still show up in cleanup-stale-envs.sh's discovery. The environment itself was torn down successfully regardless." >&2
fi
