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
