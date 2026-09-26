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
# The installer is a release asset (#828): the pinned release's own copy, or the latest release's.
# It verifies the release's GPG signature and aborts without it, so gnupg is installed for the build.
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates gnupg \
    && if [ -n "${BELLA_VERSION}" ]; then \
         INSTALLER_URL="https://github.com/Cosmic-Chimps/bella-baxter-cli/releases/download/v${BELLA_VERSION#v}/install-bella.sh"; \
       else \
         INSTALLER_URL="https://github.com/Cosmic-Chimps/bella-baxter-cli/releases/latest/download/install-bella.sh"; \
       fi \
    && curl -sSfL -o /tmp/install-bella.sh "${INSTALLER_URL}" \
    && bash /tmp/install-bella.sh \
    && rm -f /tmp/install-bella.sh \
    && apt-get purge -y --auto-remove curl gnupg \
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
