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
