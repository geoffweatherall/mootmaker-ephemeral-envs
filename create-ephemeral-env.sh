#!/usr/bin/env bash
# Stands up a fresh ephemeral environment: generates a name, then deploys
# mootmaker-api and mootmaker-webapp into it (as sibling checkouts) by
# shelling out to each project's own deploy.sh - no deploy mechanics are
# duplicated here. mootmaker-demo-data is deployed too if --with-demo-data
# is passed: demo data is always deployed to production, but most ephemeral
# work does not need ~500 generated meetings, so it is opt-in here. See README.md for the naming
# convention and the sweep.
#
# Does NOT touch the shared email-reading pipeline (mootmaker-email-testing), which is persistent
# and not created per environment.
#
# Usage: ./create-ephemeral-env.sh [claude|web-acc|...] [--with-demo-data] [--keep "<reason>"]
#   claude (default) - an AI session's own environment, reused for the whole
#                       session rather than per task
#   <anything else>  - names what created it: a person's name, or an automated
#                       suite such as "web-acc" (mootmaker-webapp's
#                       acceptance/run.sh) or "and-acc" (mootmaker-android)
#
#   --keep "<reason>" - mark the environment as deliberately kept once it is up
#                       (keep-env.sh), so the scheduled sweep leaves it alone
#                       however long it sits idle. Written only after a
#                       SUCCESSFUL create, so a half-built environment is
#                       still swept.
#
#   --with-demo-data - also deploy mootmaker-demo-data, and seed the
#                       environment by invoking it once. Without this the
#                       environment comes up empty, which is what most work
#                       wants. Teardown does not need to be told either way:
#                       it discovers what is deployed from the state prefix.
#
# Prints the generated environment name as the last line of stdout on
# success.
set -euo pipefail

# No `cd "$(dirname "$0")"` here - it breaks when invoked via a relative path with a directory
# component (e.g. `./mootmaker-ephemeral-envs/create-ephemeral-env.sh` from a parent dir), colliding
# with the BASH_SOURCE-based cd below.

with_demo_data=""
keep_reason=""
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-demo-data) with_demo_data="true"; shift ;;
    --keep)
      keep_reason="${2:-}"
      if [[ -z "${keep_reason// /}" ]]; then
        echo "--keep needs a reason, e.g. --keep \"left up for Geoff to inspect\"" >&2
        exit 1
      fi
      shift 2
      ;;
    -*)
      echo "Unknown option: $1" >&2
      echo "Usage: ./create-ephemeral-env.sh [claude|web-acc|...] [--with-demo-data] [--keep \"<reason>\"]" >&2
      exit 1
      ;;
    *) positional+=("$1"); shift ;;
  esac
done

kind="${positional[0]:-claude}"
# kind identifies WHAT created the environment, not just that it's ephemeral - see the usage
# comment above. Kept short (max 8 characters here) to leave room under the 22-character
# environment-name ceiling - "-YYMMDD-<rand4>" below is a fixed 12 characters, so kind's own
# budget is 22 - 12 = 10, capped a little tighter for some safety margin.
if [[ ! "${kind}" =~ ^[a-z][a-z0-9-]{0,7}$ ]]; then
  echo "Usage: ./create-ephemeral-env.sh [claude|web-acc|...]" >&2
  echo "kind must be lowercase letters/digits/hyphens, starting with a letter, 8 characters or fewer - got: '${kind}'" >&2
  exit 1
fi

# Day-only timestamp + short random suffix. The 22-character ceiling comes from AWS resource-name
# limits: the longest Lambda name, <environment>-mootmaker-post-confirmation-create-person, leaves
# 22 characters under Lambda's 64-character limit. There is no room for a time of day, and the
# random suffix makes same-day collisions negligible.
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
demo_data_dir="${script_dir}/../mootmaker-demo-data"

if [[ ! -f "${api_dir}/deploy.sh" ]]; then
  echo "Expected to find the mootmaker-api checkout at ${api_dir} (as a sibling of this directory)." >&2
  exit 1
fi
if [[ ! -f "${webapp_dir}/deploy.sh" ]]; then
  echo "Expected to find the mootmaker-webapp checkout at ${webapp_dir} (as a sibling of this directory)." >&2
  exit 1
fi
if [[ -n "${with_demo_data}" && ! -f "${demo_data_dir}/deploy.sh" ]]; then
  echo "Expected to find the mootmaker-demo-data checkout at ${demo_data_dir} (as a sibling of this directory)." >&2
  exit 1
fi

trap 'echo "create-ephemeral-env.sh failed partway through - environment '"'"'${name}'"'"' may be partially deployed. Clean up with: ./teardown-ephemeral-env.sh ${name}" >&2' ERR

echo "Creating ephemeral environment '${name}' (kind: ${kind})..." >&2

# Redirected to stderr: both deploy.sh scripts print their own progress (and the full
# mvn/npm/terraform build output) to stdout, unredirected - fine when run directly, but this
# script's own contract is "prints the generated environment name as the last line of stdout",
# relied on by callers like run-full-stack-tests.sh that capture it via $(...). Left unredirected,
# that captured value would be the entire build transcript instead of the environment name.
"${api_dir}/deploy.sh" "${name}" >&2
"${webapp_dir}/deploy.sh" "${name}" >&2

if [[ -n "${with_demo_data}" ]]; then
  # After mootmaker-api, always: demo-data reads its credentials from SSM parameters that
  # mootmaker-api's Terraform creates, so deploying it first would give a Lambda that fails on
  # every invocation with a missing-parameter error.
  "${demo_data_dir}/deploy.sh" "${name}" >&2

  # Deploying demo-data does not populate anything - the Lambda only runs when invoked. Seed once
  # here so --with-demo-data means "an environment with demo data in it", not "an environment that
  # could have some". --cli-read-timeout clears the function's own 900s ceiling; the CLI's 60s
  # default would report a false failure on a full seed while the Lambda ran on regardless.
  echo "Seeding '${name}' with demo data..." >&2
  aws lambda invoke \
    --function-name "${name}-mootmaker-demo-data" \
    --cli-read-timeout 900 \
    --payload '{}' \
    /dev/stdout >&2
fi

trap - ERR

if [[ -n "${keep_reason}" ]]; then
  "${script_dir}/keep-env.sh" "${name}" "${keep_reason}"
fi

echo "Ephemeral environment '${name}' is up." >&2
echo "${name}"
