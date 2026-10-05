#!/usr/bin/env bash
# Marks an ephemeral environment as deliberately kept, so the scheduled sweep leaves it alone.
#
# WHY THIS EXISTS. The sweep's age guard measures when Terraform state was last WRITTEN, not whether
# anyone is still using the environment. During its report-only trial it flagged
# claude-261003-bxun, kept at Geoff's request, and his own geoff-261002-wvyl as "stranded" - both
# would have been destroyed had it been acting (mootmaker#51). This is how an environment says
# "idle, but on purpose".
#
# The marker is an object at s3://remote-state-<account>/<environment>/KEEP holding the reason, who
# kept it and when. A reason is required: the sweep prints it on every run, alongside how long the
# environment has been kept, so a forgotten keep stays visible instead of quietly costing money.
# teardown-ephemeral-env.sh removes the marker with the rest of the environment's state.
#
# Usage: ./keep-env.sh <environment> "<reason>"
#        ./unkeep-env.sh <environment>          (removes the marker; the sweep then applies again)
set -euo pipefail

name="${1:-}"
reason="${2:-}"
if [[ -z "${name}" || -z "${reason// /}" ]]; then
  echo "Usage: ./keep-env.sh <environment> \"<reason>\"" >&2
  echo "A reason is required - it is what the sweep prints every day while the environment is kept." >&2
  exit 1
fi

# Only ephemeral environments are swept, so only they can be kept. Refusing anything else stops a
# typo'd name from creating a marker that protects nothing.
if [[ ! "${name}" =~ ^[a-z][a-z0-9-]{0,7}-[0-9]{6}-[a-z0-9]{4}$ ]]; then
  echo "'${name}' is not an ephemeral environment name (<kind>-<YYMMDD>-<rand4>)." >&2
  exit 1
fi

account_id="$(aws sts get-caller-identity --query Account --output text)"
bucket="remote-state-${account_id}"

# Must already have state: a marker for an environment that does not exist would sit in the bucket
# looking like a kept environment forever.
if ! aws s3api list-objects-v2 --bucket "${bucket}" --prefix "${name}/" --query 'Contents[].Key' \
     --output text 2>/dev/null | tr '\t' '\n' | grep -q '/terraform\.tfstate$'; then
  echo "No Terraform state found for '${name}' in s3://${bucket} - nothing to keep." >&2
  exit 1
fi

kept_by="$(aws sts get-caller-identity --query Arn --output text | sed -E 's|.*/||')"
printf 'reason: %s\nkept-by: %s\nkept-at: %s\n' "${reason}" "${kept_by}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  | aws s3 cp - "s3://${bucket}/${name}/KEEP" --content-type text/plain >/dev/null

echo "'${name}' is marked as kept: ${reason}" >&2
echo "The sweep will skip it until ./unkeep-env.sh ${name}, or until it is torn down." >&2
