# Task 3: Food delivery schema proof

This folder implements **Step 5 only**: PostgreSQL schema, sample data, five requirement-driven queries, two query plans, and three rejected invalid inserts. There is no application server, payment processing, worker, GraphQL server, or live tracking implementation.

## Run the proof

Requires Node.js 20+ and npm:

```sh
npm ci
npm test
```

Each run creates a fresh in-memory PostgreSQL database using PGlite and rewrites the evidence files. It does not connect to or modify any existing database. The dependency is pinned in package-lock.json. UUID values and execution timings will differ between runs.

For native PostgreSQL 16+ use a **new empty database** and run:

```sh
psql "$TASK3_DATABASE_URL" -v ON_ERROR_STOP=1 -f migration.sql
psql "$TASK3_DATABASE_URL" -v ON_ERROR_STOP=1 -f seed.sql
psql "$TASK3_DATABASE_URL" -v ON_ERROR_STOP=1 -f queries.sql
psql "$TASK3_DATABASE_URL" -v ON_ERROR_STOP=1 -f plans.sql
psql "$TASK3_DATABASE_URL" -v ON_ERROR_STOP=1 -f invalid-inserts.sql
```

The migration intentionally does not drop existing objects. Seed data is intended for a fresh database, not repeated application to the same database.

## Files

- `migration.sql`: eight entities, constraints, indexes, timestamps, and lifecycle enforcement.
- `seed.sql`: 24 restaurants and menu items, 60 customers, 6 couriers, and 1,200 orders with line items; deliveries and reviews follow legal transitions. This modest volume makes query plans meaningful without a production-size dataset.
- `queries.sql`: the five main actions' representative database queries.
- `plans.sql`: EXPLAIN ANALYZE with buffers for restaurant incoming orders and courier discovery, the two broadest queue queries.
- `invalid-inserts.sql`: zero quantity, review before delivery, and second active delivery for a busy courier. Each expected failure is caught and reported; unexpected outcomes stop execution.
- `run-proof.mjs`: isolated runner and additional targeted checks.
- `concurrency-test.mjs`: real two-connection concurrency test against a native PostgreSQL server (see below). Not run by `npm test`.
- `.env.example`: template for the connection strings `concurrency-test.mjs` needs. Copy to `.env` (gitignored) and fill in real values; never commit `.env`.
- `evidence/`: saved executed results, query plans, a browser-renderable view of the constraint results and its screenshot, and the Neon concurrency test output.
- `diagrams/`: copies of the supplied ER and lifecycle diagrams, unchanged, plus their exported `.svg`/`.png` renders for embedding in [`../DESIGN.md`](../DESIGN.md).

SQL uses snake_case names; the document/API use camelCase. `orders` is the Order entity. `bigint` stores integer minor units, not decimals. Currency is a three-uppercase-letter code; the prototype does not claim an exhaustive ISO currency catalogue.

## Enforcement choices

Every order begins placed. Only the documented state-machine edges are allowed; all other state changes fail. Moving to picked_up or delivered requires an assignment and writes the corresponding delivery timestamp in the same transaction. Actor permissions remain part of the API contract; this schema proof does not implement authentication.

Deferred checks require at least one item and verify the final sum at commit. New items must be available, belong to the order's restaurant, and carry its currency and current menu price. Later menu edits do not change stored prices. Items and order totals are not editable after creation; rejected/cancelled orders retain their records. Database triggers enforce immutable references, rather than relying on an absent API update path or incomplete column grants.

The courier assignment trigger locks the courier then the order before checking eligibility and existing active work. Its documented isolation is READ COMMITTED. Assignment cannot be reassigned through UPDATE. The embedded PGlite runtime (`npm test`) only proves sequential rejection of a second assignment; the genuine two-session race is proven separately by `concurrency-test.mjs` against a real Neon server — see "Neon two-connection concurrency test" below.

Review.order_id is immutable and insertion requires a delivered order. The unique order_id constraint retains the one-review-per-order rule even if a review is soft-deleted. Review moderation and account-deletion endpoints remain out of scope; deleted_at records schema policy only.

Transaction deletion is prohibited by triggers. This prototype does not implement a retention/anonymisation administrator workflow or claim that all personal data should be kept permanently.

## Index reasoning

- `restaurant_orders(restaurant_id,status,created_at DESC,id)` supports filtering and ordering the restaurant queue.
- `assignable_orders(created_at,id)` is partial over accepted/preparing/ready and supports oldest-first discovery.
- Delivery's unique order_id index supports excluding assigned orders.
- `courier_deliveries(courier_id)` supports busy checks.
- OrderItem's unique `(order_id,menu_item_id)` already supports line-item lookup; a duplicate order_id index is unnecessary.
- Customer history and restaurant menu indexes support the corresponding scoped reads.

No planner flags force index use. Small tables may correctly use sequential scans. The runner confirms that the two queue plans actually reference the intended order indexes. These are illustrative plans for the seeded data, not performance guarantees for production.

## Neon two-connection concurrency test

`npm test` (PGlite) only proves the courier-exclusivity trigger rejects a **sequential** second
assignment — it is a single embedded connection and cannot demonstrate a real race.
`concurrency-test.mjs` opens two independent connections to a native PostgreSQL server, has one hold
an assignment transaction open while the other genuinely contends for the same courier's row lock,
confirms the second connection actually blocks (not just fails fast), then verifies it is rejected
specifically with `one_active_delivery_per_courier` once the first commits — and runs the same check
with the launch order reversed. It is intended to run once against a **new, empty Neon project**.

```sh
npm install                      # installs pg, used only by this script
# In the Neon console: create a new project, then copy its connection strings.
cp .env.example .env             # gitignored; edit it and fill in DIRECT_URL (the non-pooled endpoint)
set -a && source .env && set +a  # load DIRECT_URL into this shell, for the two psql commands below
psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -f migration.sql
psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -f seed.sql
npm run test:concurrency         # this step loads .env itself; the export above isn't needed for it
```

`cp .env.example .env` only creates the file — it doesn't put `DIRECT_URL` into your shell's
environment, so the `psql` commands would otherwise see it unset. `npm run test:concurrency` doesn't
need the `source` step: it runs `node --env-file-if-exists=.env`, which loads `.env` itself.

The script writes `evidence/concurrency-test.txt` (PostgreSQL version, connection/isolation setup,
both connections' backend PIDs, both scenarios' outcomes, and the final-state assertion; no
credentials are written). It has bounded waits (a `lock_timeout` on the contending session plus a
whole-script watchdog) so a failure exits instead of hanging.

**Result: PASSED**, run against a fresh Neon project (PostgreSQL 18.6). Both launch orders showed
genuine blocking (confirmed via two distinct backend PIDs, not just sequential execution), and the
contending connection was rejected specifically with `one_active_delivery_per_courier` each time, with
exactly one active assignment confirmed afterward. See
[`evidence/concurrency-test.txt`](evidence/concurrency-test.txt) for the full output.

## Remaining submission work

- The published post about a modelling decision — not done; this folder does not claim otherwise.

Steps 1–4 (requirements, entity model, design reasoning, and full API contracts including the
REST/GraphQL and SSE/WebSocket analysis) are written up in [`../DESIGN.md`](../DESIGN.md), not in
this file.

### Evidence capture

The three rejection messages are actual database output in `evidence/invalid-inserts.txt`. `evidence/constraint-results.html` presents those same messages for review, and `evidence/constraint-results-screenshot.png` is a screenshot of that page.
