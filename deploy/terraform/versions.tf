# PENDING - WRITTEN BUT NOT APPLIED (as of 2026-08-15). See ses.tf in this
# directory and mootmaker-e2e/testing-strategy.md for why: "ses", "sns", and
# "sqs" aren't yet on this account's Service Control Policy allow-list
# (mootmaker-bootstrap-aws-accounts/management-account/scp-guardrails.yaml),
# so no API call against any of them - including `terraform plan` - can
# succeed yet. `terraform validate` (pure local syntax/internal-consistency
# check, no AWS calls) passes; that's as far as this has been exercised.
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Bucket/region/locking are supplied via backend.hcl; `key` is fixed (not
  # per-environment) - see backend.hcl for why.
  backend "s3" {}
}
