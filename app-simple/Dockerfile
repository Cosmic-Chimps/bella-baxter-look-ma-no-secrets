# ─── Build stage ────────────────────────────────────────────────────────────
FROM node:24-slim AS deps

WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

# ─── Runtime stage ──────────────────────────────────────────────────────────
# node:24-slim is Debian-based (glibc) — compatible with the bella Linux binary.
FROM node:24-slim AS runtime

# Install the Bella CLI via the official install script.
# Pin a version with: docker build --build-arg BELLA_VERSION=v1.2.3 .
ARG BELLA_VERSION=
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && if [ -n "${BELLA_VERSION}" ]; then \
         curl -sSfL https://raw.githubusercontent.com/cosmic-chimps/bella-baxter-cli/main/scripts/install-bella.sh \
           | bash -s -- --version "${BELLA_VERSION}"; \
       else \
         curl -sSfL https://raw.githubusercontent.com/cosmic-chimps/bella-baxter-cli/main/scripts/install-bella.sh \
           | bash; \
       fi \
    && apt-get purge -y --auto-remove curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY server.js ./
COPY db/ ./db/

EXPOSE 3000

# bella run fetches secrets from Bella and injects them into the environment,
# then exec's the real command. No SDK required — works with any language/framework.
# The database password is NEVER written to any file on disk.
ENTRYPOINT ["bella", "run", "--"]
CMD ["node", "server.js"]
