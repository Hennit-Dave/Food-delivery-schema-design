# Food delivery platform — Task 3

A design document plus a small implemented PostgreSQL schema proof for a food-delivery product
(customers order from restaurants; restaurants prepare; couriers deliver). This is **not** a
running application — no server, payments, frontend, or authentication is implemented. See
[AGENTS.md](AGENTS.md) (handoff context and agreed scope) in the repository root.

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


