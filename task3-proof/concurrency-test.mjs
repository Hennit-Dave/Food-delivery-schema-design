// Real two-connection concurrency proof for the courier-exclusivity trigger (assign_courier()
// in migration.sql). PGlite (run-proof.mjs) is a single embedded connection and can only prove
// SEQUENTIAL rejection; this script proves the SAME rejection under genuine connection overlap
// against a real PostgreSQL server (intended target: a fresh Neon project).
//
// Requires DIRECT_URL (Neon's non-pooled endpoint) with migration.sql and seed.sql already
// applied once. Never run against a database you care about; this script inserts delivery rows.
//
// Usage:
//   npm install
//   cp .env.example .env   # fill in DIRECT_URL from a NEW Neon project
//   npm run test:concurrency

import pg from 'pg';
import { writeFile } from 'node:fs/promises';

const DIRECT_URL = process.env.DIRECT_URL;
if (!DIRECT_URL) {
  console.error(
    'DIRECT_URL is not set.\n' +
    'Copy .env.example to .env, fill in a NEW Neon project\'s direct connection string, then run:\n' +
    '  npm run test:concurrency'
  );
  process.exit(1);
}

const LOCK_TIMEOUT_MS = 15000; // safety net on the contending session: fail loudly, never hang
const BLOCK_CHECK_MS = 1500;   // how long we wait before concluding the contender is genuinely blocked
const WATCHDOG_MS = 60000;     // whole-script safety net

const settle = (promise) =>
  promise.then(
    (value) => ({ ok: true, value }),
    (error) => ({ ok: false, error })
  );
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function connect(label) {
  const client = new pg.Client({ connectionString: DIRECT_URL });
  await client.connect();
  const {
    rows: [{ pid }],
  } = await client.query('SELECT pg_backend_pid() AS pid');
  return { client, label, pid };
}

async function pickFreeCouriers(client, n) {
  const { rows } = await client.query(
    `SELECT id, name FROM courier
     WHERE deleted_at IS NULL
     AND NOT EXISTS (
       SELECT 1 FROM delivery d JOIN orders o ON o.id = d.order_id
       WHERE d.courier_id = courier.id AND o.status NOT IN ('delivered','cancelled')
     )
     ORDER BY name LIMIT $1`,
    [n]
  );
  return rows;
}

async function pickEligibleOrders(client, n) {
  const { rows } = await client.query(
    `SELECT id FROM orders
     WHERE status IN ('accepted','preparing','ready')
     AND NOT EXISTS (SELECT 1 FROM delivery d WHERE d.order_id = orders.id)
     ORDER BY created_at LIMIT $1`,
    [n]
  );
  return rows;
}

async function runScenario({ label, courier, winner, loser, winnerOrder, loserOrder, log }) {
  log(`\n--- Scenario: ${label} ---`);
  log(`Courier: ${courier.name} (${courier.id})`);
  log(`${winner.label} order: ${winnerOrder.id}  |  ${loser.label} order: ${loserOrder.id}`);
  log(`${winner.label} backend pid=${winner.pid}  |  ${loser.label} backend pid=${loser.pid} (two distinct physical connections)`);

  await winner.client.query('BEGIN');
  await winner.client.query('SET TRANSACTION ISOLATION LEVEL READ COMMITTED');
  await loser.client.query('BEGIN');
  await loser.client.query('SET TRANSACTION ISOLATION LEVEL READ COMMITTED');
  await loser.client.query(`SET LOCAL lock_timeout = '${LOCK_TIMEOUT_MS}ms'`);

  await winner.client.query('INSERT INTO delivery(order_id, courier_id) VALUES ($1,$2)', [
    winnerOrder.id,
    courier.id,
  ]);
  log(`${winner.label} inserted its assignment and is holding the transaction open (not committed yet).`);

  const loserPromise = loser.client.query('INSERT INTO delivery(order_id, courier_id) VALUES ($1,$2)', [
    loserOrder.id,
    courier.id,
  ]);
  const loserOutcome = settle(loserPromise); // never rejects; inspected after the race

  const race = await Promise.race([
    loserOutcome.then((r) => ({ tag: 'settled', r })),
    delay(BLOCK_CHECK_MS).then(() => ({ tag: 'pending' })),
  ]);

  const blockingObserved = race.tag === 'pending';
  log(
    blockingObserved
      ? `${loser.label} is still blocked after ${BLOCK_CHECK_MS}ms, as expected (waiting on the courier-row lock ${winner.label} holds).`
      : `WARNING: ${loser.label} did not block; it settled before ${winner.label} committed.`
  );

  await winner.client.query('COMMIT');
  log(`${winner.label} committed.`);

  const finalLoser = await loserOutcome;
  let loserResult;
  if (finalLoser.ok) {
    loserResult = { rejected: false };
    log(`FAIL: ${loser.label}'s competing assignment unexpectedly succeeded.`);
  } else {
    const err = finalLoser.error;
    loserResult = { rejected: true, message: err.message, constraint: err.constraint, code: err.code };
    log(`${loser.label} rejected: [${err.code}] ${err.message}${err.constraint ? ` (constraint: ${err.constraint})` : ''}`);
  }
  await loser.client.query('ROLLBACK');

  const expected = 'one_active_delivery_per_courier';
  const passConstraint = loserResult.rejected && (loserResult.constraint === expected || loserResult.message === expected);

  const {
    rows: [{ count }],
  } = await winner.client.query(
    `SELECT count(*)::int AS count FROM delivery d JOIN orders o ON o.id=d.order_id
     WHERE d.courier_id=$1 AND o.status NOT IN ('delivered','cancelled')`,
    [courier.id]
  );
  const passFinalState = count === 1;
  log(`Final state: courier has ${count} active assignment(s) (expected 1).`);

  const pass = passConstraint && blockingObserved && passFinalState;
  log(pass ? 'Scenario PASSED.' : 'Scenario FAILED.');

  return { label, blockingObserved, loserResult, finalActiveCount: count, pass };
}

async function main() {
  const lines = [];
  const log = (s) => {
    console.log(s);
    lines.push(s);
  };

  const a = await connect('Connection A');
  const b = await connect('Connection B');

  const {
    rows: [{ version }],
  } = await a.client.query('select version()');
  log(`Command context: node concurrency-test.mjs (two node-postgres Client connections to DIRECT_URL)`);
  log(`PostgreSQL: ${version}`);
  log('Endpoint: DIRECT_URL (non-pooled); two independent physical connections, confirmed below by distinct backend PIDs.');
  log('Isolation: READ COMMITTED, set explicitly on both sessions.');
  log(
    `Safety nets: lock_timeout=${LOCK_TIMEOUT_MS}ms on the contending session, ${BLOCK_CHECK_MS}ms blocking-confirmation window, ${WATCHDOG_MS}ms whole-script watchdog.`
  );

  const couriers = await pickFreeCouriers(a.client, 2);
  if (couriers.length < 2) {
    throw new Error(`Need 2 free couriers, found ${couriers.length}. Reseed the database (fresh migration.sql + seed.sql) and rerun.`);
  }
  const orders = await pickEligibleOrders(a.client, 4);
  if (orders.length < 4) {
    throw new Error(`Need 4 eligible unassigned orders, found ${orders.length}. Reseed the database and rerun.`);
  }

  const results = [];
  results.push(
    await runScenario({
      label: 'A holds the lock first, B contends',
      courier: couriers[0],
      winner: a,
      loser: b,
      winnerOrder: orders[0],
      loserOrder: orders[1],
      log,
    })
  );
  results.push(
    await runScenario({
      label: 'B holds the lock first, A contends (reversed launch order)',
      courier: couriers[1],
      winner: b,
      loser: a,
      winnerOrder: orders[2],
      loserOrder: orders[3],
      log,
    })
  );

  await a.client.end();
  await b.client.end();

  const allPass = results.every((r) => r.pass);
  log(`\nOverall: ${allPass ? 'PASS' : 'FAIL'}`);

  await writeFile(new URL('./evidence/concurrency-test.txt', import.meta.url), lines.join('\n') + '\n');
  console.log('\nWrote evidence/concurrency-test.txt');
  if (!allPass) process.exit(1);
}

const watchdog = setTimeout(() => {
  console.error(`Watchdog: concurrency test exceeded ${WATCHDOG_MS}ms. Exiting to avoid hanging.`);
  process.exit(1);
}, WATCHDOG_MS);
watchdog.unref();

main()
  .then(() => clearTimeout(watchdog))
  .catch((err) => {
    console.error('Concurrency test failed:', err);
    process.exit(1);
  });
