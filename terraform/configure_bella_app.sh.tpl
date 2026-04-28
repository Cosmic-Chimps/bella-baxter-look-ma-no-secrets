#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# configure_bella_app.sh.tpl  —  uploaded + executed by Terraform null_resource
#
# Terraform-injected variables (filled in by templatefile()):
#   bella_baxter_url, bella_app_api_key
#   bella_project, bella_env, app_repo_url, app_repo_branch
#
# ⚠️  ESCAPING RULES:
#   - $${var} → Terraform template interpolation (renders to the value; use $${name} in template)
#   - $VAR    → plain shell variable (Terraform passes through untouched)
#   - $(cmd)  → shell command substitution (Terraform passes through untouched)
#   - DO NOT use $$ outside of $${...} — bash expands $$ as the current PID.
# ─────────────────────────────────────────────────────────────────────────────

# ── Terraform-injected values (resolved at plan/apply time) ──────────────────
BELLA_BAXTER_URL="${bella_baxter_url}"
BELLA_APP_API_KEY="${bella_app_api_key}"
APP_REPO_URL="${app_repo_url}"
APP_REPO_BRANCH="${app_repo_branch}"

APP_DIR="/home/ubuntu/look-ma-no-secrets"

# ── 1. Node.js 20 ─────────────────────────────────────────────────────────────
echo ">>> Installing Node.js 20..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs git
echo ">>> Node: $(node --version)  npm: $(npm --version)"

# ── 2. pm2 ────────────────────────────────────────────────────────────────────
echo ">>> Installing pm2..."
sudo npm install -g pm2

# ── 3. Bella CLI ──────────────────────────────────────────────────────────────
# Use GitHub's /releases/latest/download/ redirect — no version lookup needed.
echo ">>> Installing Bella CLI (latest)..."
curl -fsSL \
  "https://github.com/Cosmic-Chimps/bella-baxter-cli/releases/latest/download/cli-linux-x64" \
  -o /tmp/bella
sudo install -m 755 /tmp/bella /usr/local/bin/bella
echo ">>> Bella: $(bella --version)"

# ── 3b. Bella ZKE setup ───────────────────────────────────────────────────────
# Generates a per-device P-256 keypair for zero-knowledge encryption.
# Skipped if a keypair already exists (re-deploys on the same instance reuse the same key).
echo ">>> Setting up Bella ZKE keypair..."
BELLA_BAXTER_API_KEY="$BELLA_APP_API_KEY" \
  BELLA_BAXTER_URL="$BELLA_BAXTER_URL" \
  bella auth setup \
  || echo ">>> ZKE keypair already exists, reusing."
echo ">>> ZKE keypair ready."

# ── 4. Clone repo ─────────────────────────────────────────────────────────────
echo ">>> Cloning $APP_REPO_URL @ $APP_REPO_BRANCH..."
git clone --branch "$APP_REPO_BRANCH" --depth 1 "$APP_REPO_URL" "$APP_DIR"

# ── 5. Install dependencies ───────────────────────────────────────────────────
echo ">>> npm install — app-simple (bella run, no ZKE)..."
npm install --omit=dev \
  --prefix "$APP_DIR/app-simple"

echo ">>> npm install — app (bella sdk run + ZKE)..."
npm install --omit=dev \
  --prefix "$APP_DIR/app"

# ── 6. pm2 ecosystem file ─────────────────────────────────────────────────────
# Use an unquoted heredoc so the shell expands $VAR → actual values at write time.
cat > /home/ubuntu/ecosystem.config.js << ECOSYSTEM
module.exports = {
  apps: [
    {
      name: 'lmns-simple',
      script: '/usr/local/bin/bella',
      args: 'run -- node server.js',
      cwd: '$APP_DIR/app-simple',
      restart_delay: 5000,
      max_restarts: 10,
      env: {
        NODE_ENV:             'production',
        PORT:                 '3001',
        BELLA_BAXTER_API_KEY: '$BELLA_APP_API_KEY',
        DB_SSL:               'true',
      },
    },
    {
      name: 'lmns-sdk',
      script: '/usr/local/bin/bella',
      args: 'sdk run -- node server.js',
      cwd: '$APP_DIR/app',
      restart_delay: 5000,
      max_restarts: 10,
      env: {
        NODE_ENV:             'production',
        PORT:                 '3002',
        BELLA_BAXTER_API_KEY: '$BELLA_APP_API_KEY',
        DB_SSL:               'true',
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
sudo env PATH="$PATH:/usr/local/bin:/usr/bin" \
  pm2 startup systemd -u ubuntu --hp /home/ubuntu

pm2 save

# ── Summary ───────────────────────────────────────────────────────────────────
PUBLIC_IP=$(curl -sf https://api.ipify.org || echo "unknown")
echo ""
echo "================================================================"
echo "  Both apps running via pm2!"
echo ""
echo "  Simple app (bella run, no ZKE):"
echo "       http://$PUBLIC_IP:3001"
echo "       http://$PUBLIC_IP:3001/health"
echo "       http://$PUBLIC_IP:3001/products"
echo "       http://$PUBLIC_IP:3001/db-test"
echo ""
echo "  SDK app (bella sdk run + ZKE):"
echo "       http://$PUBLIC_IP:3002"
echo "       http://$PUBLIC_IP:3002/health"
echo "       http://$PUBLIC_IP:3002/products"
echo "       http://$PUBLIC_IP:3002/db-test"
echo ""
echo "  DATABASE_URL lives in Bella -- not on this machine."
echo "  Secrets injected at process startup via bella run / bella sdk run."
echo "================================================================"
