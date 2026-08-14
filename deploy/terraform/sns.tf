# PENDING - see ses.tf's top comment: not applied until "sns" is on the SCP
# allow-list.
data "aws_caller_identity" "current" {}

resource "aws_sns_topic" "inbound_email" {
  name = "mootmaker-e2e-inbound-email"
}

# Lets the SES receipt rule (ses.tf) publish to this topic. Scoped to
# publishes originating from this AWS account, which is as tight as SES's
# own recommended policy shape gets (SES doesn't expose a stable per-rule
# ARN to scope AWS:SourceArn to more narrowly).
data "aws_iam_policy_document" "inbound_email_topic" {
  statement {
    sid       = "AllowSESPublish"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.inbound_email.arn]

    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "inbound_email" {
  arn    = aws_sns_topic.inbound_email.arn
  policy = data.aws_iam_policy_document.inbound_email_topic.json
}

# Raw delivery so the queue gets the SES notification JSON directly rather
# than wrapped in an SNS envelope - one less layer for the test suite to
# unwrap when parsing the verification code out of the email body.
resource "aws_sns_topic_subscription" "inbound_email_to_sqs" {
  topic_arn            = aws_sns_topic.inbound_email.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.inbound_email.arn
  raw_message_delivery = true
}
