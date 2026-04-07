variable "aws_region" {
  description = "AWS region where the S3 bucket will be created"
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "Name of the S3 bucket to create for Terraform remote state"
  type        = string
  default     = "cosmic-chimps-tf-state"
}
