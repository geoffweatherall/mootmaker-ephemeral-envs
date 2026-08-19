bucket       = "remote-state-431071856068"
key          = "mootmaker-e2e-email/terraform.tfstate"
region       = "us-east-1"
use_lockfile = true

# `key` is a fixed, flat key rather than the usual
# "<environment>/mootmaker-e2e/terraform.tfstate" pattern every other
# project's deploy.sh computes at init time - deliberately, mirroring
# mootmaker-domain's own backend.hcl ("domain/terraform.tfstate"). This
# infrastructure (SES receipt rule, SNS topic, SQS queue) is one persistent,
# shared pipeline, not something created per ephemeral environment - see
# ses.tf and mootmaker-test-infra/testing-strategy.md for why. Using a fixed key
#
# NOTE: the key and the resource names in this directory still say
# "mootmaker-e2e" even though this repo is now mootmaker-test-infra - that's
# deliberate. Changing a state key means re-pointing Terraform at an empty
# state for already-live resources; changing the SQS/SNS/SES resource `name`s
# would force a destroy+recreate of a pipeline other tests actively depend
# on. Neither is worth doing as a side effect of a repo rename - if it's ever
# wanted, do it as its own deliberate, explicitly-approved step.
# also means cleanup-stale-envs.sh's discovery logic (which groups state
# keys by first path segment and matches only claude-*/e2e-* names) never
# mistakes this for a stale ephemeral environment and offers to tear it
# down.
