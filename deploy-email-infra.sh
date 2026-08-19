#!/usr/bin/env bash
# Deploys the SES receipt rule set, SNS topic, and SQS queue that implement
# real-email reading, shared across every frontend's tests (see testing-strategy.md
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

echo "Deploying shared test email infrastructure (SES receipt rule / SNS / SQS)..."

terraform -chdir=deploy/terraform init -backend-config=backend.hcl -input=false
terraform -chdir=deploy/terraform apply -auto-approve

echo
echo "Deployed. SQS queue: $(terraform -chdir=deploy/terraform output -raw sqs_queue_url)"
