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
