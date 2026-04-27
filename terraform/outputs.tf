# ─── Infrastructure ───────────────────────────────────────────────────────────

output "public_ip" {
  description = "EC2 elastic public IP"
  value       = aws_eip.dokploy.public_ip
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.dokploy.id
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (private — not publicly accessible)"
  value       = aws_db_instance.app.endpoint
}

# ─── SDK app (bella sdk run + ZKE) ───────────────────────────────────────────

output "app_sdk_url" {
  description = "SDK app base URL (bella sdk run + ZKE, port 3002)"
  value       = "http://${aws_eip.dokploy.public_ip}:3002"
}

output "app_sdk_endpoints" {
  description = "SDK app endpoints"
  value = {
    health       = "http://${aws_eip.dokploy.public_ip}:3002/health"
    products     = "http://${aws_eip.dokploy.public_ip}:3002/products"
    deploys      = "http://${aws_eip.dokploy.public_ip}:3002/deploys"
    db_test      = "http://${aws_eip.dokploy.public_ip}:3002/db-test"
    secrets_demo = "http://${aws_eip.dokploy.public_ip}:3002/secrets-demo"
  }
}

# ─── Simple app (bella run — no ZKE) ─────────────────────────────────────────

output "app_simple_url" {
  description = "Simple app base URL (bella run, no ZKE, port 3001)"
  value       = "http://${aws_eip.dokploy.public_ip}:3001"
}

output "app_simple_endpoints" {
  description = "Simple app endpoints"
  value = {
    health       = "http://${aws_eip.dokploy.public_ip}:3001/health"
    products     = "http://${aws_eip.dokploy.public_ip}:3001/products"
    deploys      = "http://${aws_eip.dokploy.public_ip}:3001/deploys"
    db_test      = "http://${aws_eip.dokploy.public_ip}:3001/db-test"
    secrets_demo = "http://${aws_eip.dokploy.public_ip}:3001/secrets-demo"
  }
}

# ─── Bella secrets ────────────────────────────────────────────────────────────

output "bella_secrets_created" {
  description = "Secrets that Terraform stored in Bella Baxter"
  value = {
    rds_password = bella_secret.rds_password.id
    database_url = bella_secret.database_url.id
  }
}

# ─── SSH ──────────────────────────────────────────────────────────────────────

output "bella_ssh_sign_command" {
  description = "Step 1: Sign your personal SSH key via Bella (valid 8h)"
  value       = "bella ssh sign --role ops-team --project ${var.bella_project} --env ${var.bella_env}"
}

output "ssh_connect_command" {
  description = "Step 2: SSH in after signing (your key is now trusted by the instance)"
  value       = "ssh ubuntu@${aws_eip.dokploy.public_ip}"
}

output "quick_ssh_command" {
  description = "SSH using the Terraform-generated key (no personal key needed, for debugging)"
  value       = "ssh -i ${path.module}/.terraform-ssh-key ubuntu@${aws_instance.dokploy.public_ip}"
}

output "ca_public_key" {
  description = "Bella SSH CA public key (already installed on the instance)"
  value       = data.bella_ssh_ca_public_key.this.ca_public_key
}
