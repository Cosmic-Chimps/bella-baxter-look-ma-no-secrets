# Look Ma! No Secrets! 🙌

> **One `terraform apply` provisions AWS infrastructure, stores all credentials in Bella Baxter,
> and deploys an Express app that connects to a private RDS database — with zero database
> secrets anywhere in Docker Compose, version control, or config files.**

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

## Secret rotation

Because `DATABASE_URL` lives in Bella:

1. Rotate the RDS password in AWS (or via Terraform `taint`)
2. Update `bella_secret.database_url` and `bella_secret.rds_password` in Terraform
3. Redeploy the container — `bella run` fetches the new value on next startup

No code changes, no config file edits, no secret ever touches a repository.
