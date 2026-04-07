# ─────────────────────────────────────────────────────────────────────────────
# bootstrap/main.tf
#
# ONE-TIME SETUP — run this manually (once, locally) to create the S3 bucket
# that holds the remote Terraform state for the main look-ma-no-secrets config.
#
# This config intentionally uses local state (backend "local") to avoid the
# chicken-and-egg problem of needing a bucket before you can create the bucket.
#
# Usage:
#   cd terraform/bootstrap
#   terraform init
#   terraform apply
#   # Note the bucket_name output → set it as TF_STATE_BUCKET in GitHub Secrets
#
# After this runs once, never destroy it (prevent_destroy = true).
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.3.0"

  # Intentionally local state — this is a one-time bootstrap config.
  # Do NOT add an S3 backend here.
  backend "local" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ─── S3 State Bucket ─────────────────────────────────────────────────────────

resource "aws_s3_bucket" "tf_state" {
  bucket = var.bucket_name

  tags = {
    Name        = var.bucket_name
    ManagedBy   = "terraform-bootstrap"
    Project     = "look-ma-no-secrets"
    Description = "Terraform remote state for look-ma-no-secrets demo"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
