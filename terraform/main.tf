terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    bella = {
      source  = "cosmic-chimps/bella-baxter"
      version = "~> 0.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }

  # Remote state — used by GitHub Actions (CI).
  # For local development, override with a backend_override.tf (gitignored):
  #
  #   terraform {
  #     backend "local" {}
  #   }
  #
  # Or run: terraform init -reconfigure -backend=false
  backend "s3" {
    # Bucket and key are passed at init time via -backend-config or env vars:
    #   TF_CLI_ARGS_init="-backend-config=bucket=my-tf-state -backend-config=key=lmns/terraform.tfstate"
    # In CI these are set from GitHub Secrets (TF_STATE_BUCKET, TF_STATE_KEY).
    # Region must match the bucket's region — defaults to us-east-1.
    region = "us-east-1"
    encrypt        = true
    use_lockfile   = true  # native S3 state locking (Terraform ≥ 1.10, no DynamoDB needed)
  }
}

provider "aws" {
  region = var.aws_region
}

provider "bella" {
  baxter_url = var.bella_baxter_url
  # api_key intentionally omitted — set via BELLA_API_KEY env var (OIDC exchange in CI)
  app_name   = var.app_name
  # private_key intentionally omitted — set via BELLA_BAXTER_PRIVATE_KEY env var
}

# ────────────────────────────────────────────────────────────────────────────
# Secrets — generated here, stored in Bella (never in tfvars or config files)
# ────────────────────────────────────────────────────────────────────────────

resource "random_password" "rds" {
  length  = 32
  special = false
}

locals {
  db_password  = random_password.rds.result
  database_url = "postgresql://${var.db_username}:${random_password.rds.result}@${aws_db_instance.app.address}:5432/${var.db_name}?sslmode=require"

  # Compute deterministic sslip.io domains from the Elastic IP.
  # These are registered in Dokploy via domain.create so Traefik routes them.
  ip_dashed     = replace(aws_eip.dokploy.public_ip, ".", "-")
  sdk_domain    = "lmns-sdk.${local.ip_dashed}.sslip.io"
  simple_domain = "lmns-run.${local.ip_dashed}.sslip.io"
}

# Store RDS password in Bella Baxter
resource "bella_secret" "rds_password" {
  provider_slug = var.bella_provider_slug
  key           = "RDS_PASSWORD"
  value         = local.db_password
  description   = "RDS master password - managed by Terraform"
}

# Store full DATABASE_URL in Bella Baxter
# The app reads this via `bella sdk run --` — it never appears in docker-compose.yml
resource "bella_secret" "database_url" {
  provider_slug = var.bella_provider_slug
  key           = "DATABASE_URL"
  value         = local.database_url
  description   = "Full PostgreSQL connection string - managed by Terraform"

  depends_on = [aws_db_instance.app]
}

# ── Step 1: Bella SSH — declare the role ────────────────────────────────────
#
# bella_ssh_role creates a named role in Bella Baxter's SSH CA.
# The role controls which Unix usernames certificates may target and how
# long they stay valid. A single role can be shared by many team members.

resource "bella_ssh_role" "ops" {
  name          = "ops-team"
  allowed_users = var.ssh_allowed_users
  default_ttl   = "8h"
  max_ttl       = "24h"
}

# ── Step 2: Bella SSH — read the CA public key ───────────────────────────────
#
# bella_ssh_ca_public_key fetches the CA public key for this project/env.
# We write it to the EC2 instance via user_data so that sshd trusts
# any certificate signed by Bella's CA.

data "bella_ssh_ca_public_key" "this" {
  # CA key is always available once SSH is configured on the environment
  depends_on = [bella_ssh_role.ops]
}


# ── Step 3: Bella SSH — sign a Terraform-generated key for provisioning ──────
#
# During `terraform apply` we generate a temporary key pair so that
# Terraform's "connection" block can SSH in to run provisioners.
# The private key stays in Terraform state; the signed certificate is
# short-lived (1h) and scoped to the "ubuntu" user.
#
# In normal day-to-day use, operators sign THEIR OWN public key via:
#   bella ssh sign --project my-project --env production --role ops-team
# and then SSH directly — no Terraform involvement needed.

resource "tls_private_key" "terraform_provisioner" {
  algorithm = "ED25519"
}

data "bella_ssh_signed_certificate" "terraform_provisioner" {
  role_name        = bella_ssh_role.ops.name
  public_key       = tls_private_key.terraform_provisioner.public_key_openssh
  valid_principals = "ubuntu"
  ttl              = "1h"
}


# Write the signed certificate next to the private key so openssh can find it.
# The file name MUST be <private_key_file>-cert.pub for OpenSSH auto-detection.
resource "local_sensitive_file" "terraform_cert" {
  filename        = "${path.module}/.terraform-ssh-cert.pub"
  content         = data.bella_ssh_signed_certificate.terraform_provisioner.signed_key
  file_permission = "0600"
}

# Write the provisioner private key to disk so operators can SSH without needing
# their own key pair. Use: ssh -i .terraform-ssh-key ubuntu@<ip>
# (OpenSSH auto-loads .terraform-ssh-cert.pub because of the matching name)
resource "local_sensitive_file" "terraform_private_key" {
  filename        = "${path.module}/.terraform-ssh-key"
  content         = tls_private_key.terraform_provisioner.private_key_openssh
  file_permission = "0600"
}


# ────────────────────────────────────────────────────────────────────────────
# VPC & Networking
# ────────────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.app_name}-vpc", Project = var.app_name }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.app_name}-igw", Project = var.app_name }
}

# Public subnet — Dokploy EC2
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.app_name}-public", Project = var.app_name }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.app_name}-public-rt", Project = var.app_name }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Allow SSH inbound only — no hardcoded key pairs needed.
resource "aws_security_group" "ssh" {
  name        = "bella-ssh-example"
  description = "Allow inbound SSH (CA-cert-only)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "bella-ssh-example" }
}


# Private subnets — RDS (needs two AZs for subnet group)
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.10.0/24"
  availability_zone = "${var.aws_region}a"
  tags              = { Name = "${var.app_name}-private-a", Project = var.app_name }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = "${var.aws_region}b"
  tags              = { Name = "${var.app_name}-private-b", Project = var.app_name }
}

# ────────────────────────────────────────────────────────────────────────────
# Security Groups
# ────────────────────────────────────────────────────────────────────────────

resource "aws_security_group" "dokploy" {
  name        = "${var.app_name}-dokploy-sg"
  description = "Dokploy host - SSH, Dokploy UI, HTTP/S, app port"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = var.allowed_ssh_cidr
  }
  ingress {
    description = "Dokploy UI"
    from_port   = 3000
    to_port = 3000
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port = 443
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "App-demo SDK (bella sdk run)"
    from_port   = 3001
    to_port     = 3001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "App-demo simple (bella run)"
    from_port   = 3002
    to_port     = 3002
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.app_name}-dokploy-sg", Project = var.app_name }
}

resource "aws_security_group" "rds" {
  name        = "${var.app_name}-rds-sg"
  description = "RDS - only reachable from Dokploy EC2"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from Dokploy"
    from_port       = 5432
    to_port = 5432
    protocol = "tcp"
    security_groups = [aws_security_group.dokploy.id]
  }
  egress {
    from_port   = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.app_name}-rds-sg", Project = var.app_name }
}

# ────────────────────────────────────────────────────────────────────────────
# RDS PostgreSQL (private subnet — NOT publicly accessible)
# ────────────────────────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "main" {
  name       = "${var.app_name}-db-subnet-group"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  tags       = { Name = "${var.app_name}-db-subnet-group", Project = var.app_name }
}

resource "aws_db_instance" "app" {
  identifier             = "${var.app_name}-db"
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = var.db_instance_class
  allocated_storage      = 20
  storage_type           = "gp3"
  storage_encrypted      = true

  db_name  = var.db_name
  username = var.db_username
  password = local.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  skip_final_snapshot    = true
  deletion_protection    = false

  tags = { Name = "${var.app_name}-db", Project = var.app_name }
}

# ────────────────────────────────────────────────────────────────────────────
# AMI — Latest Ubuntu 22.04 LTS
# ────────────────────────────────────────────────────────────────────────────

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ────────────────────────────────────────────────────────────────────────────
# EC2 Instance — Dokploy host
# ────────────────────────────────────────────────────────────────────────────

resource "aws_instance" "dokploy" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ssh.id]

  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail

    # ── Trust Bella's SSH CA ──────────────────────────────────────────────────
    mkdir -p /etc/ssh
    cat > /etc/ssh/bella_ca.pub <<'CAKEY'
    ${data.bella_ssh_ca_public_key.this.ca_public_key}
    CAKEY

    # Configure sshd to trust Bella CA certificates
    cat >> /etc/ssh/sshd_config <<'SSHD'

    # Bella Baxter SSH CA — managed by Terraform
    TrustedUserCAKeys /etc/ssh/bella_ca.pub
    PasswordAuthentication no
    PermitRootLogin no
    SSHD

    systemctl restart sshd
    echo "Bella SSH CA configured ✓"
  EOF

  tags = {
    Name      = "bella-ssh-example"
    ManagedBy = "terraform"
  }
}

resource "aws_eip" "dokploy" {
  instance = aws_instance.dokploy.id
  domain   = "vpc"
  tags     = { Name = "${var.app_name}-eip", Project = var.app_name }
}

# ────────────────────────────────────────────────────────────────────────────
# Deploy the demo app via Dokploy API
# Runs after RDS is up + Bella secrets are stored
# ────────────────────────────────────────────────────────────────────────────

resource "null_resource" "deploy_app" {
  depends_on = [
    aws_eip.dokploy,
    bella_secret.database_url,
    bella_secret.rds_password,
  ]

  triggers = {
    instance_id         = aws_instance.dokploy.id
    repo                = var.app_repo_url
    sdk_compose_path    = var.sdk_compose_path
    simple_compose_path = var.simple_compose_path
    # Redeploy if Bella secrets change
    db_secret_id  = bella_secret.database_url.id
    pwd_secret_id = bella_secret.rds_password.id
  }

  connection {
    type        = "ssh"
    host        = aws_instance.dokploy.public_ip
    user        = "ubuntu"
    private_key = tls_private_key.terraform_provisioner.private_key_openssh
    certificate = data.bella_ssh_signed_certificate.terraform_provisioner.signed_key
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Connected via Bella SSH certificate ✓'",
      "whoami",
      "hostname",
    ]
  }

  provisioner "file" {
    content = templatefile("${path.module}/configure_bella_app.sh.tpl", {
      dokploy_admin_email    = var.dokploy_admin_email
      dokploy_admin_password = var.dokploy_admin_password
      github_token           = var.github_token
      app_repo_url           = var.app_repo_url
      app_repo_branch        = var.app_repo_branch
      sdk_compose_path       = var.sdk_compose_path
      simple_compose_path    = var.simple_compose_path
      bella_baxter_url       = var.bella_baxter_url
      bella_app_api_key      = var.bella_app_api_key
      bella_app_private_key  = var.bella_app_private_key
      bella_project          = var.bella_project
      bella_env              = var.bella_env
    })
    destination = "/home/ubuntu/configure_bella_app.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /home/ubuntu/configure_bella_app.sh",
      "/home/ubuntu/configure_bella_app.sh 2>&1 | tee /home/ubuntu/configure_bella_app.log",
    ]
  }
}
