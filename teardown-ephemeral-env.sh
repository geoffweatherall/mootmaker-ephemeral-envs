#!/usr/bin/env bash
# Tears down one specific, already-known ephemeral environment: calls
# undeploy.sh for mootmaker-webapp then mootmaker-api (sibling checkouts).
# This is what create-ephemeral-env.sh's failure trap points at, and what
# Claude's commit-time cleanup prompt (see mootmaker/testing-strategy.md
# #ephemeral-environment-lifecycle) uses once the user confirms.
#
# Refuses to run against anything that doesn't look like a claude-*/e2e-*
# ephemeral environment name - this is a hard safety rail (a typo must never
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

# Must look exactly like claude-<YYMMDD>-<rand4> or e2e-<YYMMDD>-<rand4> - see
# mootmaker/testing-strategy.md#environments for the naming convention
# (day-only timestamp, no HHmm - see create-ephemeral-env.sh for why).
# Deliberately strict: this script's whole job is to be safe to point at an
# arbitrary string without risking "test" or "production".
if [[ ! "${name}" =~ ^(claude|e2e)-[0-9]{6}-[a-z0-9]{4}$ ]]; then
  echo "'${name}' doesn't look like a claude-*/e2e-* ephemeral environment name (expected e.g. claude-260815-x7q2 or e2e-260815-x7q2)." >&2
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
