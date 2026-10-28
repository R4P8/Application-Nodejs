#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ShipTrack project bootstrapper.
# Run inside an EMPTY folder, then:  docker compose up --build -d
# Requires the external network + Postgres container to exist already:
#   docker network create pulsebox-net      (if missing)
#   docker ps --filter name=pulsebox-db
# ---------------------------------------------------------------------------
set -euo pipefail

echo "Creating ShipTrack project in: $(pwd)"

mkdir -p "api"
mkdir -p "api/src"
mkdir -p "db"
mkdir -p "worker"
mkdir -p "worker/src"

cat > ".dockerignore" <<'SHIPTRACK_FILE_0'
node_modules/
npm-debug.log
.git/
.gitignore
README.md
SHIPTRACK_FILE_0

cat > ".gitignore" <<'SHIPTRACK_FILE_1'
node_modules/
npm-debug.log
.env
SHIPTRACK_FILE_1

cat > "README.md" <<'SHIPTRACK_FILE_2'
# ShipTrack

A small Node.js 20 demo (Express + node-cron) that runs on `docker-compose` and
reuses the **Postgres container from the PulseBox project** instead of starting
its own. No authentication anywhere.

Two containers:

| Service            | What it is                          | Port   |
|--------------------|-------------------------------------|--------|
| `shiptrack-api`    | Express REST API                    | `3000` |
| `shiptrack-worker` | node-cron job, runs every 10 seconds | —     |

The job deliberately fails on a schedule, so the logs and the `job_runs` table
fill up with a realistic mix of errors.

## Prerequisites

The external Postgres container and network must already exist:

```bash
docker network ls | grep pulsebox-net
docker ps --filter name=pulsebox-db
```

The API connects with `postgres://pulsebox:pulsebox@db:5432/pulsebox`, which
relies on the `--network-alias db` given to that container.

## Run

```bash
docker compose up --build -d
docker compose logs -f shiptrack-worker
```

The API creates its own tables on startup (`ensureSchema`), so nothing needs to
be applied by hand. `db/schema.sql` is a reference copy if you prefer psql.

## The job

One tick every 10 seconds, set by `CRON_EXPRESSION: "*/10 * * * * *"`.

A normal tick does: `POST /api/shipments` → `POST /api/shipments/:id/advance` →
`GET /api/shipments?limit=5`, then records the result with `POST /api/job-runs`.

Every 3rd tick fails instead (`FAIL_EVERY_N_TICKS: "3"`), cycling through six
different failure modes:

| Scenario              | How it fails                                      |
|-----------------------|---------------------------------------------------|
| `http_500`            | calls `/api/boom`, which always throws → 500      |
| `not_found_404`       | fetches shipment id `99999999` → 404              |
| `validation_400`      | posts a missing field and a negative weight → 400 |
| `db_unique_violation` | reinserts an existing tracking_code → pg 23505, 409 |
| `client_timeout`      | gives a 9s endpoint a 2s budget → AbortError      |
| `js_type_error`       | a real bug in the job code → TypeError            |

Set `FAIL_EVERY_N_TICKS: "0"` to turn chaos off, or `"1"` to make every tick
fail. Failures are caught, logged as JSON with a stack trace, and written to
`job_runs` — the schedule keeps running.

## Endpoints

```
GET  /health
POST /api/shipments               { "trackingCode": "...", "origin": "...", "destination": "...", "weightKg": 2.5 }
GET  /api/shipments?status=&limit=20
GET  /api/shipments/:id
POST /api/shipments/:id/advance
POST /api/job-runs
GET  /api/job-runs?outcome=failure&limit=20
GET  /api/stats
GET  /api/boom                    always 500, on purpose
GET  /api/slow?ms=9000            sleeps, for timeout testing
```

## Checking the traffic

```bash
curl -s http://localhost:3000/health
curl -s "http://localhost:3000/api/shipments?limit=5" | python3 -m json.tool
curl -s "http://localhost:3000/api/stats" | python3 -m json.tool

# just the failures
curl -s "http://localhost:3000/api/job-runs?outcome=failure&limit=10" | python3 -m json.tool

# trigger the errors by hand
curl -i http://localhost:3000/api/boom
curl -i http://localhost:3000/api/shipments/99999999
curl -i -X POST http://localhost:3000/api/shipments \
  -H 'content-type: application/json' -d '{"origin":"Jakarta","weightKg":-5}'
```

Straight from the database:

```bash
docker exec -it pulsebox-db psql -U pulsebox -d pulsebox -c \
  "SELECT outcome, scenario, count(*) FROM job_runs GROUP BY 1,2 ORDER BY 1,2;"
```

Every response carries an `x-request-id` header, and the API logs one JSON line
per request with the same id, so a failing job can be matched to its request.

## Layout

```
shiptrack/
├── docker-compose.yaml
├── db/schema.sql              # reference only; the API applies it itself
├── api/
│   ├── package.json
│   ├── Dockerfile
│   └── src/
│       ├── server.js          # routes + error handler
│       └── db.js              # pg pool, retry, ensureSchema
└── worker/
    ├── package.json
    ├── Dockerfile
    └── src/
        ├── worker.js          # <- the 10s job
        ├── chaos.js           # <- the deliberate failures
        └── api-client.js      # fetch wrapper with timeout
```

## Notes

- PulseBox (.NET) and ShipTrack (Node) share one Postgres instance but use
  separate tables, so they can run side by side.
- `running` guard in the worker skips a tick if the previous one is still going,
  which matters once `client_timeout` holds a cycle for 2 seconds.
- `DD_ENV` / `DD_SERVICE` / `DD_VERSION` are set for consistency with the other
  stack, but tracing needs `dd-trace` installed and required at startup — not
  wired up here.
- Credentials are hardcoded on purpose; this is a local demo.
SHIPTRACK_FILE_2

cat > "api/Dockerfile" <<'SHIPTRACK_FILE_3'
FROM node:20-alpine

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

COPY src/ ./src/

ENV NODE_ENV=production
ENV PORT=3000
EXPOSE 3000

CMD ["node", "src/server.js"]
SHIPTRACK_FILE_3

cat > "api/package.json" <<'SHIPTRACK_FILE_4'
{
  "name": "shiptrack-api",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "main": "src/server.js",
  "scripts": {
    "start": "node src/server.js"
  },
  "engines": {
    "node": ">=20"
  },
  "dependencies": {
    "express": "4.19.2",
    "pg": "8.12.0"
  }
}
SHIPTRACK_FILE_4

cat > "api/src/db.js" <<'SHIPTRACK_FILE_5'
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
SHIPTRACK_FILE_5

cat > "api/src/server.js" <<'SHIPTRACK_FILE_6'
import express from 'express';
import { randomUUID } from 'node:crypto';
import { ensureSchema, pool, query } from './db.js';

const app = express();
const PORT = Number(process.env.PORT ?? 3000);

app.use(express.json());

// Tag every request so a failing job can be matched to a log line.
app.use((req, res, next) => {
  req.id = req.get('x-request-id') ?? randomUUID();
  res.set('x-request-id', req.id);
  const startedAt = process.hrtime.bigint();

  res.on('finish', () => {
    const ms = Number(process.hrtime.bigint() - startedAt) / 1e6;
    const line = {
      level: res.statusCode >= 500 ? 'error' : res.statusCode >= 400 ? 'warn' : 'info',
      msg: `${req.method} ${req.originalUrl} -> ${res.statusCode}`,
      requestId: req.id,
      durationMs: Number(ms.toFixed(1)),
    };
    console.log(JSON.stringify(line));
  });

  next();
});

// express 4 does not forward rejected promises, so wrap async handlers.
const wrap = (handler) => (req, res, next) => Promise.resolve(handler(req, res, next)).catch(next);

const VALID_STATUSES = ['created', 'picked_up', 'in_transit', 'delivered', 'lost'];

// ---------------------------------------------------------------- system ---
app.get('/health', async (_req, res) => {
  try {
    await query('SELECT 1');
    res.json({ status: 'healthy', service: 'shiptrack-api', db: 'up', utc: new Date().toISOString() });
  } catch (err) {
    res.status(503).json({ status: 'degraded', service: 'shiptrack-api', db: 'down', error: err.message });
  }
});

app.get('/', (_req, res) => {
  res.json({
    message: 'ShipTrack parcel API',
    endpoints: [
      'GET  /health',
      'POST /api/shipments',
      'GET  /api/shipments?status=&limit=',
      'GET  /api/shipments/:id',
      'POST /api/shipments/:id/advance',
      'POST /api/job-runs',
      'GET  /api/job-runs?outcome=&limit=',
      'GET  /api/stats',
      'GET  /api/boom   (always 500, on purpose)',
      'GET  /api/slow?ms=9000  (sleeps, for timeout testing)',
    ],
  });
});

// ------------------------------------------------------------- shipments ---
app.post(
  '/api/shipments',
  wrap(async (req, res) => {
    const { trackingCode, origin, destination, weightKg } = req.body ?? {};
    const errors = {};

    if (!trackingCode || typeof trackingCode !== 'string') errors.trackingCode = 'required string';
    if (!origin) errors.origin = 'required';
    if (!destination) errors.destination = 'required';
    if (typeof weightKg !== 'number' || Number.isNaN(weightKg)) errors.weightKg = 'required number';
    else if (weightKg <= 0 || weightKg > 2000) errors.weightKg = 'must be between 0 and 2000';

    if (Object.keys(errors).length > 0) {
      return res.status(400).json({ error: 'ValidationError', requestId: req.id, details: errors });
    }

    const { rows } = await query(
      `INSERT INTO shipments (tracking_code, origin, destination, weight_kg)
       VALUES ($1, $2, $3, $4)
       RETURNING id, tracking_code, origin, destination, weight_kg, status, created_at`,
      [trackingCode.trim(), origin, destination, weightKg],
    );

    return res.status(201).location(`/api/shipments/${rows[0].id}`).json(rows[0]);
  }),
);

app.get(
  '/api/shipments',
  wrap(async (req, res) => {
    const limit = Math.min(Math.max(Number(req.query.limit) || 20, 1), 200);
    const status = req.query.status ?? null;

    const { rows } = await query(
      `SELECT id, tracking_code, origin, destination, weight_kg, status, created_at, updated_at
       FROM shipments
       WHERE ($1::text IS NULL OR status = $1)
       ORDER BY created_at DESC, id DESC
       LIMIT $2`,
      [status, limit],
    );

    res.json({ count: rows.length, items: rows });
  }),
);

app.get(
  '/api/shipments/:id',
  wrap(async (req, res) => {
    const id = Number(req.params.id);
    if (!Number.isInteger(id) || id < 1) {
      return res.status(400).json({ error: 'ValidationError', requestId: req.id, details: { id: 'must be a positive integer' } });
    }

    const { rows } = await query(
      `SELECT id, tracking_code, origin, destination, weight_kg, status, created_at, updated_at
       FROM shipments WHERE id = $1`,
      [id],
    );

    if (rows.length === 0) {
      return res.status(404).json({ error: 'NotFound', requestId: req.id, message: `shipment ${id} not found` });
    }

    return res.json(rows[0]);
  }),
);

app.post(
  '/api/shipments/:id/advance',
  wrap(async (req, res) => {
    const id = Number(req.params.id);
    const { rows } = await query('SELECT status FROM shipments WHERE id = $1', [id]);

    if (rows.length === 0) {
      return res.status(404).json({ error: 'NotFound', requestId: req.id, message: `shipment ${id} not found` });
    }

    const current = rows[0].status;
    const next = VALID_STATUSES[Math.min(VALID_STATUSES.indexOf(current) + 1, 3)];

    const updated = await query(
      `UPDATE shipments SET status = $2, updated_at = now()
       WHERE id = $1
       RETURNING id, tracking_code, status, updated_at`,
      [id, next],
    );

    return res.json({ from: current, to: next, shipment: updated.rows[0] });
  }),
);

// -------------------------------------------------------------- job runs ---
app.post(
  '/api/job-runs',
  wrap(async (req, res) => {
    const { jobName, tick, outcome, scenario, durationMs, errorMessage } = req.body ?? {};

    if (!jobName || !outcome) {
      return res.status(400).json({ error: 'ValidationError', requestId: req.id, details: { jobName: 'required', outcome: 'required' } });
    }

    const { rows } = await query(
      `INSERT INTO job_runs (job_name, tick, outcome, scenario, duration_ms, error_message)
       VALUES ($1, $2, $3, $4, $5, $6)
       RETURNING id, job_name, tick, outcome, scenario, duration_ms, error_message, ran_at`,
      [jobName, Number(tick) || 0, outcome, scenario ?? null, Number(durationMs) || 0, errorMessage ?? null],
    );

    return res.status(201).json(rows[0]);
  }),
);

app.get(
  '/api/job-runs',
  wrap(async (req, res) => {
    const limit = Math.min(Math.max(Number(req.query.limit) || 20, 1), 200);
    const outcome = req.query.outcome ?? null;

    const { rows } = await query(
      `SELECT id, job_name, tick, outcome, scenario, duration_ms, error_message, ran_at
       FROM job_runs
       WHERE ($1::text IS NULL OR outcome = $1)
       ORDER BY ran_at DESC, id DESC
       LIMIT $2`,
      [outcome, limit],
    );

    res.json({ count: rows.length, items: rows });
  }),
);

app.get(
  '/api/stats',
  wrap(async (_req, res) => {
    const shipments = await query(
      `SELECT status, COUNT(*)::int AS total, ROUND(AVG(weight_kg), 2) AS avg_weight_kg
       FROM shipments GROUP BY status ORDER BY status`,
    );

    const jobs = await query(
      `SELECT outcome,
              scenario,
              COUNT(*)::int AS total,
              MAX(ran_at)   AS last_seen
       FROM job_runs
       WHERE ran_at >= now() - INTERVAL '15 minutes'
       GROUP BY outcome, scenario
       ORDER BY outcome, scenario NULLS FIRST`,
    );

    res.json({ shipmentsByStatus: shipments.rows, jobRunsLast15m: jobs.rows });
  }),
);

// ------------------------------------------------- deliberate failure ------
app.get('/api/boom', (req, _res) => {
  // Thrown synchronously; the error handler below turns it into a 500.
  throw new Error(`deliberate failure for request ${req.id}`);
});

app.get(
  '/api/slow',
  wrap(async (req, res) => {
    const ms = Math.min(Math.max(Number(req.query.ms) || 5000, 0), 30_000);
    await new Promise((resolve) => setTimeout(resolve, ms));
    res.json({ sleptMs: ms, requestId: req.id });
  }),
);

// ----------------------------------------------------------- 404 + errors ---
app.use((req, res) => {
  res.status(404).json({ error: 'NotFound', requestId: req.id, message: `no route for ${req.method} ${req.originalUrl}` });
});

app.use((err, req, res, _next) => {
  // 23505 = unique_violation, 23502 = not_null_violation, 22P02 = invalid_text_representation
  if (err.code === '23505') {
    return res.status(409).json({
      error: 'Conflict',
      requestId: req.id,
      message: 'tracking_code already exists',
      constraint: err.constraint,
    });
  }

  if (err.code === '22P02' || err.code === '23502') {
    return res.status(400).json({ error: 'BadRequest', requestId: req.id, message: err.message, pgCode: err.code });
  }

  console.error(JSON.stringify({
    level: 'error',
    msg: err.message,
    requestId: req.id,
    stack: err.stack,
  }));

  return res.status(500).json({ error: 'InternalServerError', requestId: req.id, message: err.message });
});

// ------------------------------------------------------------- bootstrap ---
async function main() {
  await ensureSchema();

  const server = app.listen(PORT, () => console.log(`[api] listening on :${PORT}`));

  const shutdown = async (signal) => {
    console.log(`[api] ${signal} received, shutting down`);
    server.close(() => undefined);
    await pool.end().catch(() => undefined);
    process.exit(0);
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

main().catch((err) => {
  console.error(`[api] fatal: ${err.message}`);
  process.exit(1);
});
SHIPTRACK_FILE_6

cat > "db/schema.sql" <<'SHIPTRACK_FILE_7'
-- Reference copy. The API applies this itself on startup (ensureSchema),
-- because the Postgres volume already exists and docker-entrypoint-initdb.d
-- only runs on a brand new data directory.
--
-- To apply by hand instead:
--   docker exec -i pulsebox-db psql -U pulsebox -d pulsebox < db/schema.sql

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
SHIPTRACK_FILE_7

cat > "docker-compose.yaml" <<'SHIPTRACK_FILE_8'
services:
  shiptrack-api:
    build:
      context: ./api
    container_name: shiptrack-api
    labels:
      com.datadoghq.tags.env: "prod"
      com.datadoghq.tags.service: "shiptrack-api"
      com.datadoghq.tags.version: "1.0.0"
    environment:
      NODE_ENV: production
      PORT: "3000"
      # reuses the Postgres container already running on pulsebox-net
      DATABASE_URL: "postgres://pulsebox:pulsebox@db:5432/pulsebox"
      DD_ENV: "prod"
      DD_SERVICE: "shiptrack-api"
      DD_VERSION: "1.0.0"
    ports:
      - "3000:3000"
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O- http://localhost:3000/health || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 12
      start_period: 10s
    restart: unless-stopped
    networks: [pulsebox-net]

  shiptrack-worker:
    build:
      context: ./worker
    container_name: shiptrack-worker
    labels:
      com.datadoghq.tags.env: "prod"
      com.datadoghq.tags.service: "shiptrack-worker"
      com.datadoghq.tags.version: "1.0.0"
    environment:
      NODE_ENV: production
      API_BASE_URL: "http://shiptrack-api:3000"
      # ---- the job schedule: every 10 seconds ----
      CRON_EXPRESSION: "*/10 * * * * *"
      # ---- chaos: every Nth tick fails on purpose. 0 disables it. ----
      FAIL_EVERY_N_TICKS: "3"
      DD_ENV: "prod"
      DD_SERVICE: "shiptrack-worker"
      DD_VERSION: "1.0.0"
    depends_on:
      shiptrack-api:
        condition: service_healthy
    restart: unless-stopped
    networks: [pulsebox-net]

networks:
  pulsebox-net:
    external: true
SHIPTRACK_FILE_8

cat > "worker/Dockerfile" <<'SHIPTRACK_FILE_9'
FROM node:20-alpine

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

COPY src/ ./src/

ENV NODE_ENV=production

CMD ["node", "src/worker.js"]
SHIPTRACK_FILE_9

cat > "worker/package.json" <<'SHIPTRACK_FILE_10'
{
  "name": "shiptrack-worker",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "main": "src/worker.js",
  "scripts": {
    "start": "node src/worker.js"
  },
  "engines": {
    "node": ">=20"
  },
  "dependencies": {
    "node-cron": "3.0.3"
  }
}
SHIPTRACK_FILE_10

cat > "worker/src/api-client.js" <<'SHIPTRACK_FILE_11'
const BASE_URL = (process.env.API_BASE_URL ?? 'http://localhost:3000').replace(/\/$/, '');

export class ApiError extends Error {
  constructor(status, body, method, path) {
    super(`${method} ${path} failed with HTTP ${status}: ${JSON.stringify(body)}`);
    this.name = 'ApiError';
    this.status = status;
    this.body = body;
  }
}

/**
 * Thin fetch wrapper. timeoutMs uses AbortSignal, so a slow endpoint surfaces
 * as an AbortError rather than hanging the job forever.
 */
export async function request(method, path, { body, timeoutMs = 5000 } = {}) {
  const response = await fetch(`${BASE_URL}${path}`, {
    method,
    headers: body ? { 'content-type': 'application/json' } : undefined,
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(timeoutMs),
  });

  const text = await response.text();
  let parsed;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    parsed = text;
  }

  if (!response.ok) {
    throw new ApiError(response.status, parsed, method, path);
  }

  return parsed;
}

export const get = (path, options) => request('GET', path, options);
export const post = (path, body, options) => request('POST', path, { ...options, body });
SHIPTRACK_FILE_11

cat > "worker/src/chaos.js" <<'SHIPTRACK_FILE_12'
import { get, post } from './api-client.js';

export const DUPLICATE_CODE = 'SHP-DUPLICATE-SENTINEL';

/**
 * Each scenario fails in a different way on purpose, so the logs and the
 * job_runs table end up with a realistic mix of error types instead of the
 * same stack trace over and over.
 */
export const SCENARIOS = [
  {
    name: 'http_500',
    describe: 'calls an endpoint that always throws -> HTTP 500',
    run: () => get('/api/boom'),
  },
  {
    name: 'not_found_404',
    describe: 'fetches a shipment id that does not exist -> HTTP 404',
    run: () => get('/api/shipments/99999999'),
  },
  {
    name: 'validation_400',
    describe: 'posts a payload with a missing field and a bad weight -> HTTP 400',
    run: () => post('/api/shipments', { trackingCode: 'SHP-BROKEN', origin: 'Jakarta', weightKg: -5 }),
  },
  {
    name: 'db_unique_violation',
    describe: 'reinserts a tracking_code that already exists -> HTTP 409 from pg 23505',
    run: () =>
      post('/api/shipments', {
        trackingCode: DUPLICATE_CODE,
        origin: 'Jakarta',
        destination: 'Surabaya',
        weightKg: 1.5,
      }),
  },
  {
    name: 'client_timeout',
    describe: 'gives a 9s endpoint a 2s budget -> AbortError',
    run: () => get('/api/slow?ms=9000', { timeoutMs: 2000 }),
  },
  {
    name: 'js_type_error',
    describe: 'a genuine bug in the job code -> TypeError',
    run: async () => {
      const payload = await get('/api/stats');
      // shipmentsByStatus exists; "summary" does not. Reading .total off
      // undefined throws, exactly like a real mistake would.
      return payload.summary.total;
    },
  },
];

/** Seed the sentinel row so db_unique_violation conflicts every single time. */
export async function seedDuplicateSentinel() {
  try {
    await post('/api/shipments', {
      trackingCode: DUPLICATE_CODE,
      origin: 'Jakarta',
      destination: 'Surabaya',
      weightKg: 1.5,
    });
    console.log('[chaos] duplicate sentinel seeded');
  } catch (err) {
    if (err.status === 409) {
      console.log('[chaos] duplicate sentinel already present');
      return;
    }
    console.warn(`[chaos] could not seed sentinel: ${err.message}`);
  }
}
SHIPTRACK_FILE_12

cat > "worker/src/worker.js" <<'SHIPTRACK_FILE_13'
import cron from 'node-cron';
import { get, post } from './api-client.js';
import { SCENARIOS, seedDuplicateSentinel } from './chaos.js';

const JOB_NAME = 'shipment-sync';
const CRON_EXPRESSION = process.env.CRON_EXPRESSION ?? '*/10 * * * * *';
const FAIL_EVERY_N_TICKS = Number(process.env.FAIL_EVERY_N_TICKS ?? 3);

const CITIES = ['Jakarta', 'Bandung', 'Surabaya', 'Medan', 'Makassar', 'Denpasar', 'Semarang'];

let tick = 0;
let running = false;

const pick = (list) => list[Math.floor(Math.random() * list.length)];

function randomShipment() {
  let origin = pick(CITIES);
  let destination = pick(CITIES);
  while (destination === origin) destination = pick(CITIES);

  return {
    trackingCode: `SHP-${Date.now()}-${Math.floor(Math.random() * 1000)}`,
    origin,
    destination,
    weightKg: Number((Math.random() * 25 + 0.5).toFixed(2)),
  };
}

/** The happy path: POST a shipment, advance one, then GET the list back. */
async function happyPath(currentTick) {
  const created = await post('/api/shipments', randomShipment());
  console.log(
    `[tick ${currentTick}] POST /api/shipments -> 201 id=${created.id} ${created.tracking_code} ` +
      `${created.origin}->${created.destination} ${created.weight_kg}kg`,
  );

  const advanced = await post(`/api/shipments/${created.id}/advance`, {});
  console.log(`[tick ${currentTick}] POST advance -> ${advanced.from} => ${advanced.to}`);

  const list = await get('/api/shipments?limit=5');
  console.log(`[tick ${currentTick}] GET  /api/shipments -> ${list.count} rows`);

  return { scenario: 'happy_path' };
}

/** Pick the scenario for this tick, cycling through them in order. */
function chaosFor(currentTick) {
  if (FAIL_EVERY_N_TICKS <= 0 || currentTick % FAIL_EVERY_N_TICKS !== 0) return null;
  const index = Math.floor(currentTick / FAIL_EVERY_N_TICKS - 1) % SCENARIOS.length;
  return SCENARIOS[index];
}

async function runCycle() {
  if (running) {
    console.warn(`[tick ${tick}] previous cycle still running, skipping this one`);
    return;
  }

  running = true;
  tick += 1;

  const currentTick = tick;
  const startedAt = Date.now();
  const scenario = chaosFor(currentTick);

  let outcome = 'success';
  let scenarioName = 'happy_path';
  let errorMessage = null;

  try {
    if (scenario) {
      scenarioName = scenario.name;
      console.log(`[tick ${currentTick}] CHAOS "${scenario.name}" - ${scenario.describe}`);
      await scenario.run();
      // If we get here the scenario did NOT fail, which is itself suspicious.
      console.warn(`[tick ${currentTick}] chaos scenario "${scenario.name}" unexpectedly succeeded`);
    } else {
      await happyPath(currentTick);
    }
  } catch (err) {
    outcome = 'failure';
    errorMessage = `${err.name}: ${err.message}`;
    console.error(
      JSON.stringify({
        level: 'error',
        msg: `[tick ${currentTick}] job failed`,
        job: JOB_NAME,
        tick: currentTick,
        scenario: scenarioName,
        errorName: err.name,
        errorStatus: err.status ?? null,
        error: err.message,
        stack: err.stack,
      }),
    );
  }

  const durationMs = Date.now() - startedAt;

  // Record the run itself. Wrapped separately so a reporting failure never
  // masks the original error.
  try {
    await post('/api/job-runs', {
      jobName: JOB_NAME,
      tick: currentTick,
      outcome,
      scenario: scenarioName,
      durationMs,
      errorMessage: errorMessage ? errorMessage.slice(0, 500) : null,
    });
  } catch (err) {
    console.error(`[tick ${currentTick}] could not record job run: ${err.message}`);
  }

  console.log(`[tick ${currentTick}] done outcome=${outcome} scenario=${scenarioName} ${durationMs}ms`);
  running = false;
}

async function waitForApi(attempts = 20, delayMs = 3000) {
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      await get('/health', { timeoutMs: 3000 });
      console.log(`[worker] api reachable after ${attempt} attempt(s)`);
      return true;
    } catch (err) {
      console.warn(`[worker] api not reachable yet (${err.message}); retrying in ${delayMs / 1000}s`);
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
  return false;
}

async function main() {
  console.log(
    `[worker] starting. api=${process.env.API_BASE_URL} cron="${CRON_EXPRESSION}" ` +
      `failEvery=${FAIL_EVERY_N_TICKS} (0 = chaos off)`,
  );

  if (!cron.validate(CRON_EXPRESSION)) {
    throw new Error(`invalid CRON_EXPRESSION: "${CRON_EXPRESSION}"`);
  }

  await waitForApi();
  await seedDuplicateSentinel();

  cron.schedule(CRON_EXPRESSION, runCycle);
  console.log('[worker] schedule armed');
}

// These two stay quiet in a demo, but without them a stray rejection would
// kill the process and you would lose the schedule.
process.on('unhandledRejection', (reason) => {
  console.error(`[worker] unhandled rejection: ${reason instanceof Error ? reason.message : reason}`);
});

process.on('SIGTERM', () => {
  console.log('[worker] SIGTERM received, exiting');
  process.exit(0);
});

main().catch((err) => {
  console.error(`[worker] fatal: ${err.message}`);
  process.exit(1);
});
SHIPTRACK_FILE_13

echo
echo "Done. Files created:"
find . -type f | sort
echo
echo "Next:  docker compose up --build -d && docker compose logs -f shiptrack-worker"
