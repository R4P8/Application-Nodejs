import pg from 'pg';

const { Pool } = pg;

const connectionString =
  process.env.DATABASE_URL ?? 'postgres://pulsebox:pulsebox@localhost:5432/pulsebox';

export const pool = new Pool({
  connectionString,
  max: 10,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
});

pool.on('error', (err) => {
  console.error(JSON.stringify({ level: 'error', msg: 'idle pg client error', error: err.message }));
});

export const query = (text, params) => pool.query(text, params);

const SCHEMA = `
CREATE TABLE IF NOT EXISTS shipments (
    id            BIGSERIAL PRIMARY KEY,
    tracking_code TEXT         NOT NULL UNIQUE,
    origin        TEXT         NOT NULL,
    destination   TEXT         NOT NULL,
    weight_kg     NUMERIC(8,2) NOT NULL,
    status        TEXT         NOT NULL DEFAULT 'created',
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_shipments_status_created
    ON shipments (status, created_at DESC);

CREATE TABLE IF NOT EXISTS job_runs (
    id            BIGSERIAL PRIMARY KEY,
    job_name      TEXT        NOT NULL,
    tick          BIGINT      NOT NULL,
    outcome       TEXT        NOT NULL,
    scenario      TEXT,
    duration_ms   INTEGER     NOT NULL DEFAULT 0,
    error_message TEXT,
    ran_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_job_runs_outcome_ran
    ON job_runs (outcome, ran_at DESC);
`;

/**
 * Postgres is an external container here, so it may not be reachable the
 * instant this process starts. Retry, then make sure our tables exist.
 */
export async function ensureSchema({ attempts = 15, delayMs = 3000 } = {}) {
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      await pool.query(SCHEMA);
      console.log(`[db] schema ready (attempt ${attempt})`);
      return;
    } catch (err) {
      if (attempt === attempts) {
        throw new Error(`could not reach Postgres after ${attempts} attempts: ${err.message}`);
      }
      console.warn(`[db] not ready yet (${err.message}); retrying in ${delayMs / 1000}s`);
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
}
