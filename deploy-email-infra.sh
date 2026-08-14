#!/usr/bin/env bash
# PENDING - DO NOT RUN YET (as of 2026-08-15). See deploy/terraform/ses.tf's
# top comment: "ses"/"sns"/"sqs" aren't yet on this account's Service
# Control Policy allow-list, so this would fail at `terraform plan` already,
# before ever reaching `apply`. Written now so the script exists once that
# allow-list is updated - a human decision, not Claude's to make.
#
# Deploys the SES receipt rule set, SNS topic, and SQS queue that implement
# real-email reading for mootmaker-e2e (see testing-strategy.md
# #reading-cognitos-emails-in-tests). Unlike every other mootmaker-* project,
# this takes no environment argument - like mootmaker-domain, this is one
# persistent, shared pipeline, not something created per ephemeral
# environment (see deploy/terraform/ses.tf and backend.hcl for the full
# reasoning). Requires mootmaker-domain's own SES pieces (see that repo's
# ses.tf) to already be deployed and verified - this reads that domain
# identity via a `data` source, so applying this first would fail.
# NOTE: `terraform apply -auto-approve` creates real AWS resources in
# whatever account/credentials are active. Run this deliberately, not from
# automation.
set -euo pipefail
cd "$(dirname "$0")"

echo "Deploying mootmaker-e2e email infrastructure (SES receipt rule / SNS / SQS)..."

terraform -chdir=deploy/terraform init -backend-config=backend.hcl -input=false
terraform -chdir=deploy/terraform apply -auto-approve

echo
echo "Deployed. SQS queue: $(terraform -chdir=deploy/terraform output -raw sqs_queue_url)"
