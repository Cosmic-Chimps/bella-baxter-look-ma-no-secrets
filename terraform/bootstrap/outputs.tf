output "bucket_name" {
  description = "Name of the created S3 bucket — set this as the TF_STATE_BUCKET GitHub Secret"
  value       = aws_s3_bucket.tf_state.bucket
}

output "bucket_arn" {
  description = "ARN of the created S3 bucket"
  value       = aws_s3_bucket.tf_state.arn
}

output "next_steps" {
  description = "What to do after this bootstrap runs"
  value       = <<-EOT
    ✅ S3 bucket created: ${aws_s3_bucket.tf_state.bucket}

    Add these to your GitHub repository secrets:
      TF_STATE_BUCKET = ${aws_s3_bucket.tf_state.bucket}
      TF_STATE_KEY    = demos/look-ma-no-secrets/terraform.tfstate

    You can now run the main Terraform config (terraform/):
      cd ../
      terraform init -backend-config="bucket=${aws_s3_bucket.tf_state.bucket}" \
                     -backend-config="key=demos/look-ma-no-secrets/terraform.tfstate"
  EOT
}
