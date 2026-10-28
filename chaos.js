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
