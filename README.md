# Food delivery platform — Task 3

A design document plus a small implemented PostgreSQL schema proof for a food-delivery product
(customers order from restaurants; restaurants prepare; couriers deliver). This is **not** a
running application — no server, payments, frontend, or authentication is implemented. See
AGENTS.md (handoff context and agreed scope) in the repository root.

- **[DESIGN.md](DESIGN.md)** — Steps 1–4: one-page requirements, the entity model with ER/lifecycle
  diagrams, design reasoning (money, identifiers, state machine, time/deletion, constraints,
  indexes), and full API contracts including the REST-vs-GraphQL and SSE-vs-WebSocket analysis.
- **[task3-proof/](task3-proof/)** — Step 5: the actually-implemented schema. See
  [task3-proof/README.md](task3-proof/README.md) for setup and how to run it.
- **[task3-proof/evidence/](task3-proof/evidence/)** — saved output from the last run.

## Run the proof

```sh
cd task3-proof
npm ci
npm test
```

Creates a fresh in-memory PostgreSQL database (PGlite) and rewrites the evidence files; touches
nothing outside that in-memory instance.

## Status

- [x] DESIGN.md covers Steps 1–4, traced to the five main actions, with worked JSON examples.
- [x] ER and lifecycle diagrams exported to SVG/PNG (`task3-proof/diagrams/`) and verified against
      `migration.sql`, including nullable fields and `deletedAt`.
- [x] Schema proof passes: migration, seed (1,200 orders), five requirement-driven queries, two
      query plans confirmed on their intended indexes, three invalid inserts rejected by the
      database (`task3-proof/evidence/`).
- [x] **Neon two-connection concurrency test** — run against a fresh Neon project (PostgreSQL 18.6):
      genuine blocking observed, both connections confirmed distinct by backend PID, and the
      contending connection rejected specifically with `one_active_delivery_per_courier` in both
      launch orders. See `task3-proof/evidence/concurrency-test.txt` and
      [task3-proof/README.md](task3-proof/README.md#neon-two-connection-concurrency-test).
- [x] **Screenshots** of the three rejected inserts —
      `task3-proof/evidence/constraint-results-screenshot.png`.
- [ ] **Repository hosting and the public post** about a modelling decision — neither is done; not
      published or pushed without explicit authorisation.

No secrets are committed. `task3-proof/.env` (real Neon credentials, if added locally) is
gitignored; only `task3-proof/.env.example` is tracked.
