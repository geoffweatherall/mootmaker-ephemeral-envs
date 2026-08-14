# PENDING - see ses.tf's top comment: not applied until "sqs" is on the SCP
# allow-list.
#
# 14-day retention (SQS's maximum) gives generous headroom for a test run
# that's slow to poll or a debugging session days later, without needing any
# other durability mechanism - this queue is disposable/replaceable, not a
# system of record.
resource "aws_sqs_queue" "inbound_email" {
  name                      = "mootmaker-e2e-inbound-email"
  message_retention_seconds = 1209600
}

# Lets the SNS topic (sns.tf) deliver to this queue.
data "aws_iam_policy_document" "inbound_email_queue" {
  statement {
    sid       = "AllowSNSDelivery"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.inbound_email.arn]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.inbound_email.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "inbound_email" {
  queue_url = aws_sqs_queue.inbound_email.id
  policy    = data.aws_iam_policy_document.inbound_email_queue.json
}
