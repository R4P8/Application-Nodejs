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
