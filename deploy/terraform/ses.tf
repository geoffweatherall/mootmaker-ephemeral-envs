# PENDING - WRITTEN BUT NOT APPLIED (as of 2026-08-15). See versions.tf's
# top comment: "ses", "sns", and "sqs" aren't yet on this account's Service
# Control Policy allow-list, so nothing in this directory has been run
# against real AWS. `terraform validate` passes.
#
# The receipt rule set/rule, SNS topic, and SQS queue that implement Option
# 2 (real email reading) from mootmaker/testing-strategy.md
# #reading-cognitos-emails-in-tests. The domain identity and MX record this
# depends on live in mootmaker-domain instead, deployed and verified
# separately - referenced here via a `data` source rather than a hard
# remote-state dependency, mirroring how mootmaker-api/mootmaker-webapp find
# mootmaker-domain's hosted zone via data "aws_route53_zone" (see that
# project's README). Applying this directory before mootmaker-domain's
# ses.tf has been applied and the identity verified would fail at plan time
# (the data source wouldn't resolve).
#
# No environment-name concept here (see also backend.hcl and
# mootmaker-e2e/testing-strategy.md): this is one persistent, shared
# pipeline, deployed once and left running like mootmaker-domain's hosted
# zone - not created/destroyed per ephemeral environment. Two reasons:
#   1. AWS SES only allows one *active* receipt rule set per region per
#      account, so a fresh rule set per ephemeral e2e run would mean
#      concurrent runs fighting over which one is active.
#   2. Each e2e run instead sends to a uniquely-tagged address under the
#      shared subdomain and filters the SQS queue for its own tag - so
#      concurrent runs don't see each other's mail even though the pipeline
#      itself is shared. See mootmaker-e2e/testing-strategy.md for the full
#      reasoning.
data "aws_ses_domain_identity" "mail" {
  domain = "mail.mootmaker.com"
}

resource "aws_ses_receipt_rule_set" "e2e" {
  rule_set_name = "mootmaker-e2e-inbound"
}

# SES only delivers mail through the single rule set marked active per
# region/account. Making this the active set is what actually turns on
# receiving for mail.mootmaker.com - see the block comment above for why
# there's deliberately only ever one rule set here, not one per environment.
resource "aws_ses_active_receipt_rule_set" "e2e" {
  rule_set_name = aws_ses_receipt_rule_set.e2e.rule_set_name
}

# Matches every address under the subdomain (specifying a bare domain as the
# recipient, rather than a full address, makes SES match all recipients at
# that domain) and publishes each message to the SNS topic below. SES
# receipt rules can't deliver to SQS directly - hence the SNS hop, which the
# queue below subscribes to.
resource "aws_ses_receipt_rule" "catch_all" {
  name          = "catch-all"
  rule_set_name = aws_ses_receipt_rule_set.e2e.rule_set_name
  recipients    = [data.aws_ses_domain_identity.mail.domain]
  enabled       = true
  scan_enabled  = true

  sns_action {
    topic_arn = aws_sns_topic.inbound_email.arn
    position  = 1
    encoding  = "UTF-8"
  }
}
