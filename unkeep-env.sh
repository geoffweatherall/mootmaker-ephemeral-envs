#!/usr/bin/env bash
# Removes the KEEP marker keep-env.sh wrote, so the scheduled sweep applies to the environment
# again. See keep-env.sh for what the marker is and why it exists.
#
# Usage: ./unkeep-env.sh <environment>
set -euo pipefail

name="${1:-}"
if [[ ! "${name}" =~ ^[a-z][a-z0-9-]{0,7}-[0-9]{6}-[a-z0-9]{4}$ ]]; then
  echo "Usage: ./unkeep-env.sh <environment>   (an ephemeral name, <kind>-<YYMMDD>-<rand4>)" >&2
  exit 1
fi

account_id="$(aws sts get-caller-identity --query Account --output text)"
bucket="remote-state-${account_id}"

if ! aws s3api head-object --bucket "${bucket}" --key "${name}/KEEP" >/dev/null 2>&1; then
  echo "'${name}' is not marked as kept." >&2
  exit 0
fi

aws s3 rm "s3://${bucket}/${name}/KEEP" >/dev/null
echo "'${name}' is no longer kept. The sweep will tear it down once it has been idle past its age guard." >&2
