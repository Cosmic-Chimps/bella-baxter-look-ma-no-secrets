# Look Ma! No Secrets! 🙌

> **One `terraform apply` provisions AWS infrastructure, stores all credentials in Bella Baxter,
> and deploys an Express app that connects to a private RDS database — with zero database
> secrets anywhere in Docker Compose, version control, config files, or CI/CD secrets.**

---

## The point

Open `app/docker-compose.yml`. You'll see this:

```yaml
environment:
  BELLA_BAXTER_URL: ${BELLA_BAXTER_URL}
  BELLA_CLIENT_ID: ${BELLA_CLIENT_ID}
  BELLA_CLIENT_SECRET: ${BELLA_CLIENT_SECRET}
  BELLA_ENV: ${BELLA_ENV:-production}
  BELLA_PROJECT: ${BELLA_PROJECT}
  NODE_ENV: production
  PORT: "3000"
  # NO DATABASE_URL HERE
```

No `DATABASE_URL`. No `RDS_PASSWORD`. Nothing. Safe to commit to a public repo.

`DATABASE_URL` lives in Bella Baxter. The container's `ENTRYPOINT` is `bella run --`,
which fetches secrets from Bella at startup and injects them into `process.env` before
`node server.js` launches. The database password is never written to disk anywhere on
the Dokploy host.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  terraform apply                                                │
│                                                                 │
│  1. random_password ──────────────────────────────────────┐    │
│                                                            ▼    │
│  2. aws_db_instance (RDS PostgreSQL, private subnet)      │    │
│                                                            │    │
│  3. bella_secret.rds_password ◄───────────────────────────┤    │
│     bella_secret.database_url ◄──── RDS endpoint ─────────┘    │
│                          │                                      │
│                          │ stored in Bella, not in AWS/disk     │
│                          │                                      │
│  4. aws_instance (EC2 + Dokploy)                                │
│                                                                 │
│  5. null_resource.deploy_app                                    │
│     → configure_bella_app.sh.tpl runs via SSH                  │
│     → creates Dokploy compose app                              │
│     → sets BELLA_* env vars only                               │
│     → triggers deploy                                          │
└─────────────────────────────────────────────────────────────────┘

At container startup on Dokploy:
  bella run -- node server.js
      │
      ├─ authenticates with Bella (BELLA_CLIENT_ID / SECRET)
      ├─ fetches DATABASE_URL from Bella
      ├─ injects into process.env
      └─ exec's: node server.js
                     │
                     └─ process.env.DATABASE_URL → pg.Pool → RDS
```

**Network layout:**
- EC2 (Dokploy) in public subnet — internet-facing
- RDS in private subnet — no public access
- RDS security group allows port 5432 only from EC2 security group

---

## Demo endpoints

Once deployed:

| Endpoint | Shows |
|----------|-------|
| `GET /health` | Liveness |
| `GET /products` | Rows from the RDS `products` table — proves the DB connection works |
| `GET /deploys` | Every time the container started — proves DB writes work too |
| `GET /db-test` | PostgreSQL server info |
| `GET /secrets-demo` | Env var audit — confirms `DATABASE_URL` is present but was never in Compose |

---

## Prerequisites

- AWS credentials configured (`aws configure` or `AWS_*` env vars)
- Terraform ≥ 1.3 (`brew install terraform`)
- A running Bella Baxter instance with:
  - An API client (`bella_client_id` + `bella_client_secret`)
  - A project + environment already created
  - The environment UUID and provider UUID from the Bella UI
  - **For CI/CD:** a TrustDomain configured for this GitHub repo with `GrantedRole: Manager`
    (see [CI/CD setup](#cicd--zero-secrets-in-github-actions) below)

---

## Quickstart

```bash
cd terraform

# 1. Copy and fill in your values
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 2. Init providers (downloads aws, bella, tls, random)
terraform init

# 3. Review what will be created
terraform plan

# 4. Deploy everything
terraform apply
```

`terraform apply` will:
1. Generate a random 32-char RDS password
2. Provision VPC, subnets, security groups
3. Create RDS PostgreSQL in the private subnet (~10 min)
4. Store `RDS_PASSWORD` and `DATABASE_URL` in Bella Baxter
5. Launch EC2 with Dokploy installed
6. SSH in, register the GitHub repo, set `BELLA_*` env vars, trigger deploy

When complete, `terraform output` shows:

```
app_endpoints = {
  "db_test"      = "http://1.2.3.4:3001/db-test"
  "deploys"      = "http://1.2.3.4:3001/deploys"
  "health"       = "http://1.2.3.4:3001/health"
  "products"     = "http://1.2.3.4:3001/products"
  "secrets_demo" = "http://1.2.3.4:3001/secrets-demo"
}
dokploy_ui_url = "http://1.2.3.4:3000"
```

---

## Verify the demo claim

```bash
# 1. Hit the secrets audit endpoint
curl http://<ip>:3001/secrets-demo
# Response shows DATABASE_URL is present (masked) but "Present in docker-compose.yml": false

# 2. Hit the products endpoint — real DB data from RDS
curl http://<ip>:3001/products

# 3. Check docker-compose.yml — grep for DATABASE_URL
grep DATABASE_URL app/docker-compose.yml
# Returns nothing. That's the whole point.
```

---

## Teardown

```bash
terraform destroy
```

This removes:
- EC2 instance + EIP
- RDS instance + subnet group
- VPC + all networking
- The `bella_secret` resources (deletes secrets from Bella too)

The Terraform-generated SSH key (`terraform/lmns.pem`) is deleted automatically.

---

## Project structure

```
look-ma-no-secrets/
├── .github/
│   └── workflows/
│       ├── terraform-plan.yml     ← runs on PRs, posts plan as PR comment
│       ├── terraform-apply.yml    ← runs on push to main
│       └── terraform-destroy.yml  ← manual trigger only
├── app/
│   ├── db/
│   │   └── seed.sql           ← creates products + deploys tables, seeds data
│   ├── server.js              ← Express app — reads DATABASE_URL from process.env
│   ├── package.json
│   ├── Dockerfile             ← ENTRYPOINT ["bella", "run", "--"]
│   └── docker-compose.yml     ← only BELLA_* env vars — safe to commit
└── terraform/
    ├── main.tf                ← all infrastructure + bella_secret resources
    ├── variables.tf
    ├── outputs.tf
    ├── terraform.tfvars.example
    └── configure_bella_app.sh.tpl   ← Dokploy API script (no DB creds)
```

---

## How `bella run --` works

`bella run --` is a subcommand of the Bella CLI:

1. Reads `BELLA_CLIENT_ID` + `BELLA_CLIENT_SECRET` from the environment
2. Authenticates with the Bella Baxter API at `BELLA_BAXTER_URL`
3. Fetches all secrets for `BELLA_PROJECT` in environment `BELLA_ENV`
4. Sets them as environment variables in the current process
5. `exec`s the command that follows `--` (i.e., `node server.js`) with those vars injected

The database password is in memory only, for the duration of the process. It is never written to any file, volume, or log.

---

## CI/CD — Zero Secrets in GitHub Actions

The three Terraform workflows (`terraform-plan`, `terraform-apply`, `terraform-destroy`)
use the same principle at CI level: **no `BELLA_API_KEY` is ever stored in GitHub Secrets.**

Instead, each workflow uses [bella-baxter-setup-action](https://github.com/Cosmic-Chimps/bella-baxter-setup-action)
with OIDC workload identity:

```yaml
permissions:
  id-token: write  # required for OIDC

steps:
  - uses: Cosmic-Chimps/bella-baxter-setup-action@v1
    with:
      bella-url: ${{ vars.BELLA_BAXTER_URL }}
      oidc: 'true'
```

That's it. What happens under the hood:

```
GitHub Actions runner
  │
  ├─ requests OIDC JWT from GitHub token service
  │    (claims: repo, ref, workflow, sha, actor, ...)
  │
  ├─ bella auth oidc
  │    └─ POST /api/v1/token  { oidcToken: "..." }
  │         │
  │         └─ Bella server:
  │              1. Decode JWT → extract issuer (token.actions.githubusercontent.com)
  │              2. Search TrustDomains by issuer
  │              3. Validate signature against JWKS
  │              4. Evaluate ClaimRules (e.g. repo == "org/repo", ref == "refs/heads/main")
  │              5. Issue short-lived key with GrantedRole from TrustDomain
  │
  └─ BELLA_API_KEY exported to $GITHUB_ENV (masked in logs)
       └─ terraform plan/apply uses it for bella_secret resources
```

### Full dogfooding — `bella run -- terraform`

The Terraform workflows go one step further: all sensitive `TF_VAR_*` values are stored
as secrets in Bella (not in GitHub Secrets), and `bella run --` injects them at runtime:

```yaml
# In each terraform step, instead of:
run: terraform apply -auto-approve

# The workflow uses:
run: bella run -- terraform apply -auto-approve
```

`bella run` authenticates via OIDC (same token exchange as `bella auth oidc`), then
automatically discovers which project and environment to fetch secrets from by calling
`GET /api/v1/keys/me` — the issued token already encodes the environment it's scoped to.
No `BELLA_BAXTER_PROJECT` or `BELLA_BAXTER_ENV` variables needed.

### 🏦 Bella Secrets (injected by `bella run --` at runtime)

All sensitive values live in the Bella project/environment the OIDC TrustDomain is scoped to.
`bella run -- <cmd>` fetches them and injects them as environment variables before the command runs —
so Terraform, AWS CLI, and the shell all see them automatically.

| Bella secret name | What it is |
|-------------------|------------|
| `AWS_ACCESS_KEY_ID` | AWS IAM access key |
| `AWS_SECRET_ACCESS_KEY` | AWS IAM secret key |
| `TF_STATE_BUCKET` | S3 bucket name for Terraform remote state |
| `TF_STATE_KEY` | S3 object key for the state file (e.g. `lmns/terraform.tfstate`) |
| `TF_VAR_dokploy_admin_password` | Dokploy admin password |
| `TF_VAR_bella_app_api_key` | Long-lived Bella API key for the EC2 container |

The `terraform init` step uses a `sh -c` wrapper so the shell expands `${TF_STATE_BUCKET}` and
`${TF_STATE_KEY}` **after** `bella run` has injected them — not at GitHub Actions parse time:

```yaml
run: |
  bella run -- sh -c '
    terraform init \
      -backend-config="bucket=${TF_STATE_BUCKET}" \
      -backend-config="key=${TF_STATE_KEY}"
  '
```

### 📋 GitHub Variables needed

Non-sensitive Terraform defaults are set as GitHub Variables (`vars.*`):

| Variable | Default if omitted |
|----------|--------------------|
| `BELLA_BAXTER_URL` | *(required — your Bella instance URL)* |
| `BELLA_PROVIDER_SLUG` | *(required — e.g. `baxter-openbao`)* |
| `DOKPLOY_ADMIN_EMAIL` | *(required)* |
| `AWS_REGION` | `us-east-1` |
| `PROJECT_NAME` | `lmns` |
| `APP_NAME` | `look-ma-no-secrets-demo` |
| `AMI_ID` | `ami-0905a3c97561e0b69` |

### 🔐 GitHub Secrets needed

The only remaining GitHub Secret is optional:

| Secret | Used for |
|--------|----------|
| `SLACK_WEBHOOK_URL` | Slack notifications on apply/destroy (omit to skip) |

Everything else — AWS credentials, Terraform state config, Dokploy password, Bella API key —
lives in Bella and is injected at runtime by `bella run --`.

### TrustDomain setup in Bella

In the Bella UI (or API), create a TrustDomain on the environment used by Terraform:

| Field | Value |
|-------|-------|
| **OIDC Issuer URL** | `https://token.actions.githubusercontent.com` |
| **Claim Rules** | `repository` = `your-org/look-ma-no-secrets` |
| **Granted Role** | `Manager` |
| **TTL** | `15` minutes |

The `Manager` role gives Terraform write access to create and update `bella_secret`
resources. The key expires after 15 minutes — safe even if the token were intercepted.

---

## Secret rotation

Because `DATABASE_URL` lives in Bella:

1. Rotate the RDS password in AWS (or via Terraform `taint`)
2. Update `bella_secret.database_url` and `bella_secret.rds_password` in Terraform
3. Redeploy the container — `bella run` fetches the new value on next startup

No code changes, no config file edits, no secret ever touches a repository.
