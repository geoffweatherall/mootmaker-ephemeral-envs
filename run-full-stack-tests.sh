#!/usr/bin/env bash
# Runs the full-stack Playwright suite (tests/) against a genuinely deployed webapp + API, per
# testing-strategy.md's "Deploy pipeline" - the one place a deployed webapp is tested against a
# deployed backend, including real Cognito email delivery through mootmaker-e2e's own persistent
# SES/SNS/SQS pipeline (see deploy/terraform/ - a separate, always-on piece of infrastructure,
# not created or torn down by this script).
#
# Usage:
#   ./run-full-stack-tests.sh                 create a fresh e2e-<date>-<rand> environment,
#                                              run the suite, tear it down afterward regardless
#                                              of the result (pass, fail, or a script error)
#   ./run-full-stack-tests.sh <environment>   run against an already-deployed environment
#                                              instead (e.g. one you're iterating against) -
#                                              this script never creates or tears down an
#                                              environment you passed in explicitly, that's
#                                              yours to manage
set -euo pipefail
cd "$(dirname "$0")"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
api_dir="${script_dir}/../mootmaker-api"
webapp_dir="${script_dir}/../mootmaker-webapp"

owns_environment=""
environment="${1:-}"

if [[ -z "${environment}" ]]; then
  echo "No environment given - creating a fresh one..." >&2
  environment="$("${script_dir}/create-ephemeral-env.sh" e2e)"
  owns_environment="true"
fi

cleanup() {
  if [[ -n "${owns_environment}" ]]; then
    echo "Tearing down '${environment}' (created for this run)..." >&2
    # Each undeploy.sh prompts for its own interactive "yes" (deliberately, for a human running it
    # directly - see mootmaker-api/undeploy.sh and mootmaker-webapp/undeploy.sh) - piped here so
    # this promised "tears down regardless of outcome" actually holds with no TTY attached (a CI
    # run, an unattended dev session). Safe to auto-approve unconditionally at this call site only:
    # teardown-ephemeral-env.sh's own regex check already refuses anything that doesn't look like a
    # claude-*/e2e-* ephemeral name, so by the time either destroy prompt is reached, that's already
    # guaranteed.
    yes yes | "${script_dir}/teardown-ephemeral-env.sh" "${environment}" || true
  fi
}
trap cleanup EXIT

echo "Running the full-stack suite against '${environment}'..." >&2

# Populates GRAPHQL_API_URL, COGNITO_USER_POOL_ID, COGNITO_WEBAPP_CLIENT_ID, etc. - only the
# COGNITO_* ones are actually used here (cognitoAdmin.ts), but sourcing the whole thing is simpler
# and more robust than hand-picking outputs the way this script used to.
source "${api_dir}/authenticate.sh" "${environment}"

webapp_tf_data_dir="${webapp_dir}/deploy/terraform/.terraform-${environment}"
TF_DATA_DIR="${webapp_tf_data_dir}" terraform -chdir="${webapp_dir}/deploy/terraform" init \
  -backend-config=backend.hcl \
  -backend-config="key=${environment}/mootmaker-webapp/terraform.tfstate" \
  -input=false >/dev/null
export WEBAPP_URL="$(TF_DATA_DIR="${webapp_tf_data_dir}" terraform -chdir="${webapp_dir}/deploy/terraform" output -raw site_url)"

# The email pipeline is persistent/shared (see deploy/terraform/backend.hcl) - not per
# environment, so this is the same queue regardless of which webapp/API environment is under
# test.
terraform -chdir=deploy/terraform init -backend-config=backend.hcl -input=false >/dev/null
export SQS_QUEUE_URL="$(terraform -chdir=deploy/terraform output -raw sqs_queue_url)"

npm test
