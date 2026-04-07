variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix used for all resource names"
  type        = string
  default     = "lmns"
}

variable "instance_type" {
  description = "EC2 instance type for the Dokploy host"
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 30
}

variable "allowed_ssh_cidr" {
  description = "CIDR blocks allowed to SSH. Restrict to your IP for security."
  type        = list(string)
  default     = ["0.0.0.0/0"] # ⚠️  Change to your IP: ["x.x.x.x/32"]
}

# ─── Dokploy ─────────────────────────────────────────────────────────────────

variable "dokploy_admin_email" {
  description = "Email address for the Dokploy admin account"
  type        = string
}

variable "dokploy_admin_password" {
  description = "Password for the Dokploy admin account"
  type        = string
  sensitive   = true
}

variable "github_token" {
  description = "GitHub personal access token (for Dokploy to pull the repo)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "app_repo_url" {
  description = "HTTPS URL of the GitHub repo containing the demo app"
  type        = string
  default     = "https://github.com/cosmic-chimps/bella-baxter"
}

variable "app_repo_branch" {
  description = "Branch to deploy"
  type        = string
  default     = "main"
}

variable "sdk_compose_path" {
  description = "Path to the SDK app docker-compose.yml inside the repo (bella sdk run + ZKE)"
  type        = string
  default     = "apps/demos/look-ma-no-secrets/app/docker-compose.yml"
}

variable "simple_compose_path" {
  description = "Path to the simple app docker-compose.yml inside the repo (bella run, no ZKE)"
  type        = string
  default     = "apps/demos/look-ma-no-secrets/app-simple/docker-compose.yml"
}

variable "bella_project" {
  description = "Bella Baxter project slug (encodes target project for both apps)"
  type        = string
  default     = "look-ma-no-secrets"
}

variable "bella_env" {
  description = "Bella Baxter environment name"
  type        = string
  default     = "production"
}

# ─── RDS ─────────────────────────────────────────────────────────────────────

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "PostgreSQL master username"
  type        = string
  default     = "appuser"
}

# ─── Bella Baxter ────────────────────────────────────────────────────────────

variable "bella_baxter_url" {
  description = "URL of your Bella Baxter API (e.g. https://api.bella-baxter.io)"
  type        = string
}

variable "bella_app_api_key" {
  description = "Long-lived Bella Baxter API key for the EC2 docker app (injected as BELLA_BAXTER_API_KEY)"
  type        = string
  sensitive   = true
}

variable "bella_app_private_key" {
  description = "ZKE private key for the EC2 docker app (injected as BELLA_BAXTER_PRIVATE_KEY). Generate with: bella auth setup"
  type        = string
  sensitive   = true
  default     = ""
}

variable "bella_provider_slug" {
  description = "Bella Baxter provider slug (e.g. 'my-vault'). The provider to use when storing secrets via Terraform."
  type        = string
}



variable "ami_id" {
  description = "AMI ID to use for the EC2 instance. Defaults to Ubuntu 24.04 LTS in us-east-1. Update if deploying to a different region."
  type        = string
  default     = "ami-0c7217cdde317cfec"
}

variable "ssh_allowed_users" {
  description = "Comma-separated list of SSH users the Bella certificate will be valid for."
  type        = string
  default     = "ubuntu"
}

variable "app_name" {
  description = "Name of the application. Used by Bella Baxter for identifying the app."
  type        = string
  default     = "look-ma-no-secrets-demo"
}