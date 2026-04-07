# ─── Infrastructure ───────────────────────────────────────────────────────────

output "public_ip" {
  description = "EC2 elastic public IP"
  value       = aws_eip.dokploy.public_ip
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.dokploy.id
}

output "dokploy_ui_url" {
  description = "Dokploy web UI"
  value       = "http://${aws_eip.dokploy.public_ip}:3000"
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (private — not publicly accessible)"
  value       = aws_db_instance.app.endpoint
}

# ─── SDK app (bella sdk run + ZKE) ───────────────────────────────────────────

output "app_sdk_domain" {
  description = "SDK app URL via Dokploy/Traefik (bella sdk run + ZKE)"
  value       = "http://${local.sdk_domain}"
}

output "app_sdk_endpoints" {
  description = "SDK app endpoints"
  value = {
    health       = "http://${local.sdk_domain}/health"
    products     = "http://${local.sdk_domain}/products"
    deploys      = "http://${local.sdk_domain}/deploys"
    db_test      = "http://${local.sdk_domain}/db-test"
    secrets_demo = "http://${local.sdk_domain}/secrets-demo"
  }
}

output "app_sdk_direct" {
  description = "SDK app direct IP:port fallback"
  value       = "http://${aws_eip.dokploy.public_ip}:3001"
}

# ─── Simple app (bella run — no ZKE) ─────────────────────────────────────────

output "app_simple_domain" {
  description = "Simple app URL via Dokploy/Traefik (bella run, no ZKE)"
  value       = "http://${local.simple_domain}"
}

output "app_simple_endpoints" {
  description = "Simple app endpoints"
  value = {
    health       = "http://${local.simple_domain}/health"
    products     = "http://${local.simple_domain}/products"
    deploys      = "http://${local.simple_domain}/deploys"
    db_test      = "http://${local.simple_domain}/db-test"
    secrets_demo = "http://${local.simple_domain}/secrets-demo"
  }
}

output "app_simple_direct" {
  description = "Simple app direct IP:port fallback"
  value       = "http://${aws_eip.dokploy.public_ip}:3002"
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

output "ssh_connect_command" {
  description = "Sign your personal key with Bella then SSH in"
  value       = "ssh ubuntu@${aws_eip.dokploy.public_ip}"
}

output "quick_ssh_command" {
  description = "SSH using the Terraform-generated key (no personal key needed)"
  value       = "ssh -i ${path.module}/.terraform-ssh-key ubuntu@${aws_instance.dokploy.public_ip}"
}

output "ca_public_key" {
  description = "Bella SSH CA public key (already installed on the instance)"
  value       = data.bella_ssh_ca_public_key.this.ca_public_key
}
