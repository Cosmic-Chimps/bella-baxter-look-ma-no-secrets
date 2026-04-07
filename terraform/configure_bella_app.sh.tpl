#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# configure_bella_app.sh.tpl
#
# Injected variables (Terraform templatefile syntax):
#   dokploy_admin_email, dokploy_admin_password, github_token
#   app_repo_url, app_repo_branch
#   sdk_compose_path, simple_compose_path
#   bella_baxter_url, bella_app_api_key, bella_app_private_key
#   bella_project, bella_env
#
# Deploys TWO compose services:
#   lmns-sdk    → bella sdk run (ZKE enabled)   — lmns-sdk.IP.sslip.io
#   lmns-run    → bella run    (no ZKE)          — lmns-run.IP.sslip.io
# ─────────────────────────────────────────────────────────────────────────────

ADMIN_EMAIL="${dokploy_admin_email}"
ADMIN_PASSWORD="${dokploy_admin_password}"
GITHUB_TOKEN="${github_token}"
REPO_URL="${app_repo_url}"
REPO_BRANCH="${app_repo_branch}"
SDK_COMPOSE_PATH="${sdk_compose_path}"
SIMPLE_COMPOSE_PATH="${simple_compose_path}"

BELLA_BAXTER_URL="${bella_baxter_url}"
BELLA_BAXTER_API_KEY="${bella_app_api_key}"
BELLA_BAXTER_PRIVATE_KEY="${bella_app_private_key}"
BELLA_PROJECT="${bella_project}"
BELLA_ENV="${bella_env}"

DOKPLOY_URL="http://localhost:3000"
API="$DOKPLOY_URL/api"

# ─── Helpers ─────────────────────────────────────────────────────────────────

retry() {
  local n=0 max=$1 delay=$2; shift 2
  until "$@"; do
    n=$((n+1))
    [ "$n" -ge "$max" ] && { echo "ERROR: command failed after $max attempts"; return 1; }
    echo "Attempt $n/$max failed — retrying in $${delay}s..."
    sleep "$delay"
  done
}

api_post() {
  curl -sf -X POST "$API/$1" \
    -H "Content-Type: application/json" \
    -H "$AUTH_HEADER" \
    -d "$2"
}

# ─── 1. Wait for Dokploy ─────────────────────────────────────────────────────

echo ">>> Waiting for Dokploy to become ready..."
retry 60 15 curl -sf --max-time 5 "$API/health" > /dev/null
echo ">>> Dokploy is up."

# ─── 2. Bootstrap admin account ──────────────────────────────────────────────

echo ">>> Setting up admin account..."
curl -sf -X POST "$API/auth.createAdmin" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" || true

# ─── 3. Authenticate ─────────────────────────────────────────────────────────

echo ">>> Authenticating..."
AUTH=$(curl -sf -X POST "$API/auth.login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")

TOKEN=$(echo "$AUTH" | jq -r '.token')
[ -z "$TOKEN" ] || [ "$TOKEN" = "null" ] && { echo "ERROR: no auth token"; exit 1; }
AUTH_HEADER="Authorization: Bearer $TOKEN"
echo ">>> Authenticated."

# ─── 4. Register GitHub token ────────────────────────────────────────────────

if [ -n "$GITHUB_TOKEN" ]; then
  echo ">>> Registering GitHub token..."
  api_post "gitProvider.createGithub" \
    "{\"name\":\"github\",\"accessToken\":\"$GITHUB_TOKEN\"}" || true
fi

# ─── 5. Get public IP and compute sslip.io domains ───────────────────────────

PUBLIC_IP=$(curl -sf --max-time 5 https://api.ipify.org || curl -sf --max-time 5 ifconfig.me)
IP_DASHED="${PUBLIC_IP//./-}"
SDK_DOMAIN="lmns-sdk.$${IP_DASHED}.sslip.io"
SIMPLE_DOMAIN="lmns-run.$${IP_DASHED}.sslip.io"

echo ">>> Public IP: $PUBLIC_IP"
echo ">>> SDK domain:    $SDK_DOMAIN"
echo ">>> Simple domain: $SIMPLE_DOMAIN"

# ─── 6. Create Dokploy project ───────────────────────────────────────────────

echo ">>> Creating Dokploy project..."
PROJECT_RESP=$(api_post "project.create" \
  '{"name":"look-ma-no-secrets","description":"Look Ma! No Secrets — DevSecOps demo"}')

PROJECT_ID=$(echo "$PROJECT_RESP" | jq -r '.projectId')
echo ">>> Project ID: $PROJECT_ID"

# ─── 7. Get default environment ID ───────────────────────────────────────────

echo ">>> Getting default environment..."
ENV_RESP=$(curl -sf "$API/environment.byProjectId?projectId=$PROJECT_ID" \
  -H "$AUTH_HEADER")

ENV_ID=$(echo "$ENV_RESP" | jq -r '.[0].environmentId')
echo ">>> Environment ID: $ENV_ID"

# ─── 8. Create SDK compose service (bella sdk run + ZKE) ─────────────────────

echo ">>> Creating SDK compose service..."
SDK_RESP=$(api_post "compose.create" "{
  \"name\":          \"lmns-sdk\",
  \"description\":   \"bella sdk run — ZKE enabled\",
  \"environmentId\": \"$ENV_ID\",
  \"composeType\":   \"docker-compose\"
}")

SDK_COMPOSE_ID=$(echo "$SDK_RESP" | jq -r '.composeId')
echo ">>> SDK Compose ID: $SDK_COMPOSE_ID"

# Attach repo
api_post "compose.update" "{
  \"composeId\":   \"$SDK_COMPOSE_ID\",
  \"sourceType\":  \"github\",
  \"repository\":  \"$REPO_URL\",
  \"branch\":      \"$REPO_BRANCH\",
  \"composePath\": \"$SDK_COMPOSE_PATH\"
}" > /dev/null

# Inject Bella env vars — BELLA_BAXTER_PRIVATE_KEY enables ZKE
api_post "compose.update" "{
  \"composeId\": \"$SDK_COMPOSE_ID\",
  \"env\": \"BELLA_BAXTER_URL=$BELLA_BAXTER_URL\nBELLA_BAXTER_API_KEY=$BELLA_BAXTER_API_KEY\nBELLA_BAXTER_PRIVATE_KEY=$BELLA_BAXTER_PRIVATE_KEY\nBELLA_PROJECT=$BELLA_PROJECT\nBELLA_ENV=$BELLA_ENV\"
}" > /dev/null

# Register Dokploy domain → Traefik routes lmns-sdk.IP.sslip.io → container:3000
api_post "domain.create" "{
  \"composeId\":       \"$SDK_COMPOSE_ID\",
  \"serviceName\":     \"app\",
  \"host\":            \"$SDK_DOMAIN\",
  \"port\":            3000,
  \"https\":           false,
  \"certificateType\": \"none\",
  \"domainType\":      \"compose\"
}" > /dev/null
echo ">>> SDK domain registered: http://$SDK_DOMAIN"

# ─── 9. Create simple compose service (bella run — no ZKE) ───────────────────

echo ">>> Creating simple compose service..."
SIMPLE_RESP=$(api_post "compose.create" "{
  \"name\":          \"lmns-run\",
  \"description\":   \"bella run — plain CLI, no ZKE\",
  \"environmentId\": \"$ENV_ID\",
  \"composeType\":   \"docker-compose\"
}")

SIMPLE_COMPOSE_ID=$(echo "$SIMPLE_RESP" | jq -r '.composeId')
echo ">>> Simple Compose ID: $SIMPLE_COMPOSE_ID"

# Attach repo
api_post "compose.update" "{
  \"composeId\":   \"$SIMPLE_COMPOSE_ID\",
  \"sourceType\":  \"github\",
  \"repository\":  \"$REPO_URL\",
  \"branch\":      \"$REPO_BRANCH\",
  \"composePath\": \"$SIMPLE_COMPOSE_PATH\"
}" > /dev/null

# Inject Bella env vars — NO BELLA_BAXTER_PRIVATE_KEY (no ZKE)
api_post "compose.update" "{
  \"composeId\": \"$SIMPLE_COMPOSE_ID\",
  \"env\": \"BELLA_BAXTER_URL=$BELLA_BAXTER_URL\nBELLA_BAXTER_API_KEY=$BELLA_BAXTER_API_KEY\nBELLA_PROJECT=$BELLA_PROJECT\nBELLA_ENV=$BELLA_ENV\"
}" > /dev/null

# Register Dokploy domain → Traefik routes lmns-run.IP.sslip.io → container:3000
api_post "domain.create" "{
  \"composeId\":       \"$SIMPLE_COMPOSE_ID\",
  \"serviceName\":     \"app\",
  \"host\":            \"$SIMPLE_DOMAIN\",
  \"port\":            3000,
  \"https\":           false,
  \"certificateType\": \"none\",
  \"domainType\":      \"compose\"
}" > /dev/null
echo ">>> Simple domain registered: http://$SIMPLE_DOMAIN"

# ─── 10. Deploy both services ─────────────────────────────────────────────────

echo ">>> Deploying SDK app..."
api_post "compose.deploy" "{\"composeId\":\"$SDK_COMPOSE_ID\"}" > /dev/null

echo ">>> Deploying simple app..."
api_post "compose.deploy" "{\"composeId\":\"$SIMPLE_COMPOSE_ID\"}" > /dev/null

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  ✅  Both apps deployed!"
echo ""
echo "  🌐  Dokploy UI:       http://$PUBLIC_IP:3000"
echo ""
echo "  📦  SDK app (bella sdk run + ZKE):"
echo "       http://$SDK_DOMAIN"
echo "       http://$PUBLIC_IP:3001  (direct port fallback)"
echo ""
echo "  📦  Simple app (bella run, no ZKE):"
echo "       http://$SIMPLE_DOMAIN"
echo "       http://$PUBLIC_IP:3002  (direct port fallback)"
echo ""
echo "  🔑  DATABASE_URL lives in Bella Baxter — not on this machine."
echo "════════════════════════════════════════════════════════════════"
