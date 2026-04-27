#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# configure_bella_app.sh.tpl  —  uploaded + executed by Terraform null_resource
#
# Terraform-injected variables (filled in by templatefile()):
#   bella_baxter_url, bella_app_api_key, bella_app_private_key
#   bella_project, bella_env, app_repo_url, app_repo_branch
#
# What this script does on the EC2 instance:
#   1. Installs Node.js 20 + git + pm2
#   2. Installs Bella CLI
#   3. Clones the demo repo
#   4. npm install for app-simple and app (SDK)
#   5. Writes a pm2 ecosystem.config.js
#   6. Starts both apps:
#        lmns-simple — bella run -- node server.js     (port 3001, no ZKE)
#        lmns-sdk    — bella sdk run -- node server.js (port 3002, ZKE)
#   7. Registers pm2 with systemd (survives reboots)
# ─────────────────────────────────────────────────────────────────────────────

# ── Terraform-injected values (resolved at plan/apply time) ──────────────────
BELLA_BAXTER_URL="${bella_baxter_url}"
BELLA_APP_API_KEY="${bella_app_api_key}"
BELLA_APP_PRIVATE_KEY="${bella_app_private_key}"
APP_REPO_URL="${app_repo_url}"
APP_REPO_BRANCH="${app_repo_branch}"

APP_DIR="/home/ubuntu/look-ma-no-secrets"

# ── 1. Node.js 20 ─────────────────────────────────────────────────────────────
echo ">>> Installing Node.js 20..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs git
echo ">>> Node: $$(node --version)  npm: $$(npm --version)"

# ── 2. pm2 ────────────────────────────────────────────────────────────────────
echo ">>> Installing pm2..."
sudo npm install -g pm2

# ── 3. Bella CLI ──────────────────────────────────────────────────────────────
echo ">>> Installing Bella CLI..."
BELLA_VERSION=$$(curl -sf \
  "https://api.github.com/repos/Cosmic-Chimps/bella-baxter/releases" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['tag_name'])")
echo ">>> Latest Bella version: $${BELLA_VERSION}"
curl -fsSL \
  "https://github.com/Cosmic-Chimps/bella-baxter/releases/download/$${BELLA_VERSION}/cli-linux-x64" \
  -o /tmp/bella
sudo install -m 755 /tmp/bella /usr/local/bin/bella
echo ">>> Bella: $$(bella --version)"

# ── 4. Clone repo ─────────────────────────────────────────────────────────────
echo ">>> Cloning $${APP_REPO_URL} @ $${APP_REPO_BRANCH}..."
git clone --branch "$$APP_REPO_BRANCH" --depth 1 "$$APP_REPO_URL" "$$APP_DIR"

# ── 5. Install dependencies ───────────────────────────────────────────────────
echo ">>> npm install — app-simple (bella run, no ZKE)..."
npm install --omit=dev \
  --prefix "$$APP_DIR/apps/demos/look-ma-no-secrets/app-simple"

echo ">>> npm install — app (bella sdk run + ZKE)..."
npm install --omit=dev \
  --prefix "$$APP_DIR/apps/demos/look-ma-no-secrets/app"

# ── 6. pm2 ecosystem file ─────────────────────────────────────────────────────
# Use an unquoted heredoc so shell expands $$VAR → $VAR → actual values.
# The resulting ecosystem.config.js will have values hardcoded (no runtime lookup).
cat > /home/ubuntu/ecosystem.config.js << ECOSYSTEM
module.exports = {
  apps: [
    {
      name: 'lmns-simple',
      script: '/usr/local/bin/bella',
      args: 'run -- node server.js',
      cwd: '$$APP_DIR/apps/demos/look-ma-no-secrets/app-simple',
      restart_delay: 5000,
      max_restarts: 10,
      env: {
        NODE_ENV:             'production',
        PORT:                 '3001',
        BELLA_BAXTER_API_KEY: '$$BELLA_APP_API_KEY',
      },
    },
    {
      name: 'lmns-sdk',
      script: '/usr/local/bin/bella',
      args: 'sdk run -- node server.js',
      cwd: '$$APP_DIR/apps/demos/look-ma-no-secrets/app',
      restart_delay: 5000,
      max_restarts: 10,
      env: {
        NODE_ENV:                 'production',
        PORT:                     '3002',
        BELLA_BAXTER_API_KEY:     '$$BELLA_APP_API_KEY',
      },
    },
  ],
};
ECOSYSTEM

# ── 7. Start apps + register with systemd ────────────────────────────────────
echo ">>> Starting apps with pm2..."
pm2 start /home/ubuntu/ecosystem.config.js

# Register pm2 as a systemd service (survives reboots)
# The output of pm2 startup prints the exact sudo command to run — we eval it.
sudo env PATH="$$PATH:/usr/local/bin:/usr/bin" \
  pm2 startup systemd -u ubuntu --hp /home/ubuntu

pm2 save

# ── Summary ───────────────────────────────────────────────────────────────────
PUBLIC_IP=$$(curl -sf https://api.ipify.org || echo "unknown")
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  ✅  Both apps running via pm2!"
echo ""
echo "  📦  Simple app (bella run, no ZKE):"
echo "       http://$${PUBLIC_IP}:3001"
echo "       http://$${PUBLIC_IP}:3001/health"
echo "       http://$${PUBLIC_IP}:3001/products"
echo "       http://$${PUBLIC_IP}:3001/db-test"
echo ""
echo "  📦  SDK app (bella sdk run + ZKE):"
echo "       http://$${PUBLIC_IP}:3002"
echo "       http://$${PUBLIC_IP}:3002/health"
echo "       http://$${PUBLIC_IP}:3002/products"
echo "       http://$${PUBLIC_IP}:3002/db-test"
echo ""
echo "  🔐  DATABASE_URL lives in Bella — not on this machine."
echo "  🔐  Secrets injected at process startup via bella run / bella sdk run."
echo "════════════════════════════════════════════════════════════════"
