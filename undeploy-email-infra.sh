#!/usr/bin/env bash
# Destroys the SES receipt rule set, SNS topic, and SQS queue created by
# deploy-email-infra.sh.
#
# NOTE: this is DESTRUCTIVE and IRREVERSIBLE - every e2e run relying on
# real-email verification-code tests would break until this is redeployed.
# Terraform will prompt for interactive confirmation before deleting
# anything; this script intentionally does not pass -auto-approve.
set -euo pipefail
cd "$(dirname "$0")"

echo "Undeploying shared test email infrastructure..."

terraform -chdir=deploy/terraform init -backend-config=backend.hcl -input=false
terraform -chdir=deploy/terraform destroy
