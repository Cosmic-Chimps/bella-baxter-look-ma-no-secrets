'use strict';

const express = require('express');
const { Pool } = require('pg');
const fs = require('fs');
const path = require('path');
const os = require('os');

const app = express();
const PORT = process.env.PORT ?? 3000;

// Pool is created in main() after Bella secrets are loaded into process.env.
// Routes reference it via closure — safe because requests only arrive after startup.
let pool;

// ─── Auto-migrate on startup ─────────────────────────────────────────────────
async function migrate() {
  const sql = fs.readFileSync(path.join(__dirname, 'db', 'seed.sql'), 'utf8');
  const client = await pool.connect();
  try {
    await client.query(sql);

    // Record this deploy so we can prove writes work too
    await client.query(
      `INSERT INTO deploys (environment, node_env, hostname)
       VALUES ($1, $2, $3)`,
      [
        process.env.BELLA_ENV ?? 'unknown',
        process.env.NODE_ENV  ?? 'development',
        os.hostname(),
      ]
    );

    console.log('✅  Database migration complete.');
  } finally {
    client.release();
  }
}

// ─── Routes ─────────────────────────────────────────────────────────────────

// Basic liveness check
app.get('/health', (_req, res) => {
  res.json({ ok: true, timestamp: new Date().toISOString() });
});

// List all products from the database
// This is the key demo endpoint — real data, real DB, zero hardcoded credentials
app.get('/products', async (_req, res) => {
  try {
    const result = await pool.query(
      'SELECT id, name, description, price, stock, created_at FROM products ORDER BY id'
    );
    res.json({
      ok: true,
      count: result.rowCount,
      products: result.rows,
    });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

// Show deploy history — proves the app is writing to the DB too
app.get('/deploys', async (_req, res) => {
  try {
    const result = await pool.query(
      'SELECT id, environment, node_env, hostname, started_at FROM deploys ORDER BY started_at DESC LIMIT 20'
    );
    res.json({ ok: true, deploys: result.rows });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

// Proves DATABASE_URL was injected and the app can actually reach RDS
app.get('/db-test', async (_req, res) => {
  try {
    const result = await pool.query(
      'SELECT now() AS server_time, current_database() AS db_name, version() AS pg_version'
    );
    res.json({
      ok: true,
      server_time: result.rows[0].server_time,
      db_name:     result.rows[0].db_name,
      pg_version:  result.rows[0].pg_version,
    });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

// Shows which env vars are present — masks values to avoid exposing secrets in logs
app.get('/secrets-demo', (_req, res) => {
  const BELLA_VARS = ['BELLA_BAXTER_URL', 'BELLA_BAXTER_API_KEY', 'BELLA_BAXTER_PROJECT', 'BELLA_BAXTER_ENV', 'BELLA_ENV', 'BELLA_PROJECT'];
  const APP_VARS   = ['DATABASE_URL', 'RDS_PASSWORD', 'PORT', 'NODE_ENV'];

  const mask = (key) => {
    const val = process.env[key];
    if (!val) return '(not set)';
    if (val.length <= 8) return '***';
    return `${val.substring(0, 4)}...${val.slice(-4)}`;
  };

  res.json({
    message: 'Look Ma! No secrets in Docker Compose!',
    bella_vars: Object.fromEntries(BELLA_VARS.map(k => [k, mask(k)])),
    app_vars:   Object.fromEntries(APP_VARS.map(k => [k, mask(k)])),
    proof: {
      'DATABASE_URL present':           !!process.env.DATABASE_URL,
      'Loaded by @bella-baxter/sdk':    true,
      'Present in docker-compose.yml':  false,
    },
  });
});

// ─── Start ───────────────────────────────────────────────────────────────────
async function main() {
  // Load all secrets from Bella Baxter and write them into process.env.
  // BELLA_BAXTER_URL and BELLA_BAXTER_API_KEY are injected by `bella sdk run --`.
  // Project and environment are auto-discovered from the API key via /api/v1/keys/me.
  // Dynamic import needed — @bella-baxter/sdk is ESM-only.
  const { createBellaConfig } = await import('@bella-baxter/sdk');
  const bella = await createBellaConfig({});
  bella.intoProcessEnv();

  // DATABASE_URL is now in process.env — create the pool
  pool = new Pool({
    connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: false } : false,
    connectionTimeoutMillis: 5000,
  });

  await migrate();

  app.listen(PORT, () => {
    console.log(`🚀  Server listening on port ${PORT}`);
    console.log(`    GET /health        → liveness`);
    console.log(`    GET /products      → product list from RDS`);
    console.log(`    GET /deploys       → deploy history`);
    console.log(`    GET /db-test       → PostgreSQL server info`);
    console.log(`    GET /secrets-demo  → env var audit`);
  });
}

main().catch((err) => {
  console.error('Fatal startup error:', err);
  process.exit(1);
});
