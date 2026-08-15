#!/usr/bin/env bash
# Stands up a fresh ephemeral environment: generates a name, then deploys
# mootmaker-api and mootmaker-webapp into it (as sibling checkouts) by
# shelling out to each project's own deploy.sh - no deploy mechanics are
# duplicated here. See mootmaker-e2e/testing-strategy.md#ephemeral-environment-scripts
# and mootmaker/testing-strategy.md#environments for the naming convention
# and lifecycle policy this implements.
#
# Does NOT touch the SES/SNS/SQS email-reading pipeline - that's separate,
# persistent, shared infrastructure (see testing-strategy.md), not created
# per environment.
#
# Usage: ./create-ephemeral-env.sh [claude|e2e]
#   claude (default) - Claude's own interactive dev-session environments
#   e2e              - automated e2e test-run environments
#
# Prints the generated environment name as the last line of stdout on
# success.
set -euo pipefail
cd "$(dirname "$0")"

kind="${1:-claude}"
if [[ "${kind}" != "claude" && "${kind}" != "e2e" ]]; then
  echo "Usage: ./create-ephemeral-env.sh [claude|e2e]" >&2
  echo "kind must be 'claude' or 'e2e', got: '${kind}'" >&2
  exit 1
fi

# Day-only timestamp (no time-of-day) + short random suffix - see
# mootmaker/testing-strategy.md#environments for why (AWS resource-name
# length limits once <environment>-<project-name>-... is assembled). Originally
# included HHmm too, but real deployment testing found claude-<YYMMDD>-<HHmm>-<rand4>
# (23 chars) is 1 character too long once combined with this project's longest
# Lambda function name suffix (mootmaker-post-confirmation-create-person, 41
# chars, leaves only 22 for the environment name under Lambda's 64-char limit)
# - dropping HHmm fixes it with margin to spare (18 chars) and day-level
# granularity is all the cleanup script needs anyway; the random suffix alone
# already makes same-day collisions negligible.
# The `|| true` matters: with `set -o pipefail`, `head -c4` closing the pipe
# early makes `tr` receive SIGPIPE, which would otherwise be treated as a
# pipeline failure and abort the script under `set -e`.
rand4="$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c4 || true)"
if [[ ${#rand4} -lt 4 ]]; then
  # Extremely unlikely fallback if /dev/urandom is unavailable.
  rand4="$(printf '%04x' "$((RANDOM % 65536))" | tr 'A-F' 'a-f' | tail -c4)"
fi
name="${kind}-$(date +%y%m%d)-${rand4}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
api_dir="${script_dir}/../mootmaker-api"
webapp_dir="${script_dir}/../mootmaker-webapp"

if [[ ! -f "${api_dir}/deploy.sh" ]]; then
  echo "Expected to find the mootmaker-api checkout at ${api_dir} (as a sibling of this directory)." >&2
  exit 1
fi
if [[ ! -f "${webapp_dir}/deploy.sh" ]]; then
  echo "Expected to find the mootmaker-webapp checkout at ${webapp_dir} (as a sibling of this directory)." >&2
  exit 1
fi

trap 'echo "create-ephemeral-env.sh failed partway through - environment '"'"'${name}'"'"' may be partially deployed. Clean up with: ./teardown-ephemeral-env.sh ${name}" >&2' ERR

echo "Creating ephemeral environment '${name}' (kind: ${kind})..." >&2

"${api_dir}/deploy.sh" "${name}"
"${webapp_dir}/deploy.sh" "${name}"

trap - ERR

echo "Ephemeral environment '${name}' is up." >&2
echo "${name}"
