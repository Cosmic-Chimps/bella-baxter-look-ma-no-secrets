-- ─────────────────────────────────────────────────────────────────────────────
-- seed.sql — demo schema + data for "Look Ma! No Secrets!"
--
-- Run this once against your RDS instance:
--   psql "$DATABASE_URL" -f db/seed.sql
--
-- The app will also auto-run this on first startup (idempotent).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS products (
    id          SERIAL PRIMARY KEY,
    name        TEXT        NOT NULL,
    description TEXT,
    price       NUMERIC(10,2) NOT NULL,
    stock       INTEGER     NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed data — idempotent (safe to run multiple times)
INSERT INTO products (name, description, price, stock) VALUES
    ('Widget Pro',      'The original widget, now with extra pro.',       19.99,  120),
    ('Gadget Ultra',    'A gadget so ultra, it ultras other gadgets.',    49.99,   55),
    ('Doohickey Max',   'Maximum doohickey capacity.',                     9.99,  300),
    ('Thingamajig X',   'Next-gen thingamajig with cloud integration.',   99.00,   18),
    ('Whatchamacallit', 'Nobody knows what it does, but they buy it.',    14.99,  200)
ON CONFLICT DO NOTHING;

-- Track deploys so we can prove the DB is being written to
CREATE TABLE IF NOT EXISTS deploys (
    id          SERIAL PRIMARY KEY,
    environment TEXT        NOT NULL,
    node_env    TEXT,
    hostname    TEXT,
    started_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
