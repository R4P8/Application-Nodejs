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
