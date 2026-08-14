variable "aws_region" {
  description = "AWS region this pipeline is deployed into. Must match the region mootmaker-domain's SES domain identity is verified in (see that repo's ses.tf) and be one of the regions SES supports inbound receiving in."
  type        = string
  default     = "us-east-1"
}
