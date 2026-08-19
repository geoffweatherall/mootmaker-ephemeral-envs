# PENDING - see ses.tf's top comment: these won't resolve until this
# directory has actually been applied.
output "sqs_queue_url" {
  description = "URL of the queue any frontend's e2e/acceptance tests long-poll for inbound verification-code email (see mootmaker-test-infra/testing-strategy.md#reading-cognitos-emails-in-tests)."
  value       = aws_sqs_queue.inbound_email.id
}

output "sqs_queue_arn" {
  description = "ARN of the inbound-email SQS queue."
  value       = aws_sqs_queue.inbound_email.arn
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic SES publishes inbound mail notifications to."
  value       = aws_sns_topic.inbound_email.arn
}

output "ses_receipt_rule_set_name" {
  description = "Name of the active SES receipt rule set for mail.mootmaker.com."
  value       = aws_ses_receipt_rule_set.e2e.rule_set_name
}
