# AGENTS.md — Food Delivery Schema Proof (Task 3)

## Purpose and scope

Read this file, README.md, migration.sql, run-proof.mjs, and evidence/summary.json before editing. This file is the handoff context; no access to the previous conversation or unspecified other repositories is assumed.

This is a design document with a small implemented PostgreSQL schema proof, NOT a food-delivery application. Task 3 has a 10–14-hour budget. Preserve the existing work and make targeted corrections only when necessary to satisfy the brief or fix a demonstrated defect. Passing checks are useful evidence, not proof that every possible defect is absent.

There are eight domain entities: Customer, Restaurant, Courier, MenuItem, Order, OrderItem, Delivery, Review. Payments, refunds, review moderation workflows, account-deletion workflows, live GPS, a frontend, working HTTP handlers, authentication implementation, workers, and external payment integrations are OUT OF SCOPE. Do not restore Payment or payment-related order states.

The immediate remaining work is documentation, real two-connection concurrency evidence, and diagram image exports. Do not start a new application or rewrite the schema wholesale. A deployment is not required by Task 3. Neon is the user's chosen environment for the additional concurrency test, not an assignment requirement.

## Assignment requirements and deliverables

Produce DESIGN.md with Steps 1–4 in order, followed by references to the existing Step 5 proof:

1. One-page requirements: what the product does, who uses it, and five main actions. Later design decisions must trace to these requirements.
2. Complete entity list: definitions, fields, types, required/optional status, identifiers, relationships/cardinalities, and an ER diagram.
3. All listed hard questions: normalisation/at least two deliberate denormalisations; money; status/state; time/deletion; identifiers; constraints; indexes. The brief says "seven"; cover all these topics, not just an arbitrary count of headings.
4. API contracts for the five actions AND supported basic entity operations: versioned paths/methods, typed requests, responses, errors/status codes, idempotency; pagination/filtering/sorting for every list endpoint. Include the concrete over-fetching REST/GraphQL comparison and the SSE/WebSocket analysis.
5. Implement only the schema: migration, constraints/indexes, small seeded dataset, five requirement-driven queries, actual plans on the two heaviest, and three invalid inserts rejected by the database.

Submission also needs the diagrams, query-plan output, screenshots of the three rejections, a repository, written explanation, and a public post about a modelling decision with a diagram. Track missing items honestly; do not publish or push without explicit authorisation.

## Agreed Step 1 — use as the requirements source

Product: customers order food from restaurants; restaurants prepare orders; couriers collect and deliver them.

Roles:
- Customers browse menus, place orders, track status, and review restaurants.
- Restaurants manage their own menus, accept/reject their own orders, and mark preparation progress.
- Couriers accept delivery jobs and record pickup and delivery.

Five main actions:
1. Customer places an order from a restaurant's menu.
2. Restaurant accepts/rejects the order and progresses it to ready.
3. Courier accepts the delivery and records pickup and delivery.
4. Customer receives live order-status updates without polling.
5. Customer reviews the restaurant after delivery.

Business rules:
- An order has exactly one customer and restaurant, a delivery address, and at least one available menu item from that restaurant. Quantities and prices are positive. Duplicate menuItemIds in the request are rejected.
- Server obtains prices from the menu and calculates total = sum(quantity × unit price). No fees, discounts, taxes, or client-supplied prices in this design.
- Order/item currencies match. Store unit-price and delivery-address snapshots: later ordinary edits must not change an existing order's agreed values.
- A restaurant can manage only its own menu/orders. Customer identity comes from authentication, not a request-body customerId. Only an assigned courier can record pickup/delivery.
- Courier assignment is permitted for accepted/preparing/ready orders with no existing delivery. Each courier has at most one active delivery. No reassignment workflow in this version.
- Customer may cancel only at placed; restaurant may reject only at placed. Both produce cancelled. There is no refund flow.
- Only the owning customer can review a delivered order. One restaurant review per order, rating 1–5; couriers are not rated.
- Tracking is live status only, not a GPS map.
- Historical transaction records cannot be deleted by ordinary application operations. Reference/catalogue rows use soft deletion. Administrative retention/anonymisation and moderation workflows are outside this prototype.

## Step 2 — entities and relationships

Use migration.sql for the full implemented field list; do not invent schema fields to match obsolete conversation drafts. SQL is snake_case; the document/API use camelCase. All entities have UUIDv4 ids, createdAt, and updatedAt. Mark nullable fields explicitly.

- Customer: customer identity and contact email.
- Restaurant: restaurant identity and pickup address.
- Courier: courier identity and phone.
- MenuItem: one restaurant's offered item, price/currency, availability, optional description.
- Order: customer/restaurant references, lifecycle, delivery-address snapshot, agreed total/currency.
- OrderItem: order/menu-item references, quantity, historical unit price/currency.
- Delivery: order/courier references, assignment time, optional pickup/delivery times. No separate stored status.
- Review: order reference, restaurant rating, optional comment. Customer and restaurant derive through Order.

Cardinalities:
- Customer 1 → 0..many Orders; Restaurant 1 → 0..many Orders/MenuItems.
- Order 1 → 1..many OrderItems; MenuItem 1 → 0..many OrderItems.
- Order ↔ MenuItem is many-to-many through OrderItem.
- Order 1 → 0..1 Delivery; Courier 1 → 0..many historical Deliveries, at most one active.
- Order 1 → 0..1 Review.

Original editable diagrams are diagrams/entities.html and diagrams/order-lifecycle.html. They are HTML fragments with Mermaid definitions, not image files. Export PNG/SVG images for Markdown embedding and preserve the originals. Verify exported diagrams against the SQL, including nullable fields and deletedAt.

## Step 3 — settled design reasoning

### Normalisation and snapshots

Keep customer, restaurant, courier, and current menu facts in their own tables. Explain two distinct deliberate historical copies: OrderItem.unitPriceMinor and Order.deliveryAddressSnapshot. Order.totalMinor is a third deliberate stored derived value, checked against the item sum. A historical snapshot must not be revalidated against today's menu price on later order-state updates.

### Money and identifiers

Monetary fields are integer minor units plus currency: MenuItem.priceMinor, Order.totalMinor, OrderItem.unitPriceMinor. SQL bigint is still an integer, not floating point. Currency currently validates three uppercase letters, not the full ISO catalogue. UUIDv4 prevents straightforward sequential guessing/counting; it does not replace access checks or make every form of enumeration impossible.

### Lifecycle and authority

placed → accepted → preparing → ready → picked_up → delivered.
placed → cancelled is the only cancellation edge. Initial status is placed. delivered and cancelled are terminal. Every other transition is forbidden, including skipping pickup and reopening a cancelled order.

Owning restaurant performs accepted/preparing/ready or rejection; owning customer can cancel at placed; assigned courier performs picked_up/delivered. Database triggers enforce transitions; API ownership is documented, not implemented. Delivery timestamps are updated with the order transition in the same transaction.

### Time and deletion

Every entity has createdAt and updatedAt. Customer, Restaurant, Courier, MenuItem, Review have nullable deletedAt. Order, OrderItem, Delivery reject ordinary deletion. Do not describe records as legally required to persist forever. Soft deletion does not erase personal fields; future retention policy must consider address snapshots too. isAvailable is temporary menu availability, distinct from soft deletion.

### Constraints and indexes

Read migration.sql rather than claiming that every rule has a constraint object with its prose name. Some are trigger-raised error messages. Include primary keys, NOT NULL, unique constraints, foreign keys, checks, and trigger-backed rules.

Deferred checks validate at least one item and the final item total at commit. Item insertion checks restaurant, currency, availability and initial price. Immutable references/snapshot fields are enforced by triggers, not by absence of an HTTP route. Review insertion requires delivered; its order reference is immutable. UNIQUE(order_id) on Delivery and Review prevents duplicates.

Courier assignment locks the courier row, then the order, and checks eligibility and active assignments. Intended isolation is READ COMMITTED. Its sequential rejection is tested; the simultaneous two-connection case is NOT yet demonstrated. Do not call that race verified until the remaining test passes.

Indexes already include restaurant_orders, assignable_orders, customer_orders, courier_deliveries and restaurant_menu. OrderItem's UNIQUE(order_id,menu_item_id) serves order line lookups; avoid a duplicate order_id index. Relate indexes to the actual five queries. Multi-status filtering may still require a sort; don't claim every ORDER BY is automatically covered. Preserve normal planner settings.

## Step 4 — agreed contract baseline

These are design-only contracts; do not implement an HTTP server. Authentication/ownership are assumed in the contracts, not implemented in the schema proof.

Common JSON shapes: success {"data": ...}; lists add meta {total,limit,offset,hasMore}; errors {"error":{"code":"...","message":"..."}}. IDs are UUIDs; times are ISO 8601. Use realistic synthetic examples, not actual personal data.

Mutations use Idempotency-Key scoped to actor, method and path. Same key/payload replays saved response; different payload returns 409. Persisting that mapping atomically is an API design requirement, not an already implemented feature of these eight tables. Do not claim a mapping table exists.

Shared errors: 400 malformed request/identifier/missing required idempotency header; 401 unauthenticated; 403 role/ownership failure; 404 resource not found; 409 business/state/idempotency conflict; 422 field validation; 500 unexpected failure; 503 temporary service failure. Select applicable cases explicitly for each route.

Main action routes:
- POST /api/v1/orders: required restaurantId, nonempty items[{menuItemId,quantity}], deliveryAddress{line1,city,postcode}. Identity from session; validate availability/restaurant/currency; server calculates prices. Insert placed order/items in one transaction. 201, Location, data {id,status,totalMinor,currency}. No paymentMethodId or asynchronous payment status.
- PATCH /api/v1/orders/{orderId}: required status; role-specific restaurant/customer transitions above. 200 data {id,status,updatedAt}. Unknown value 422; forbidden transition 409.
- POST /api/v1/orders/{orderId}/delivery: no body, courier from session. 201, Location, data {id,orderId,courierId,assignedAt,pickedUpAt:null,deliveredAt:null}. Busy/already-assigned/ineligible = 409.
- PATCH /api/v1/orders/{orderId}/delivery: status picked_up or delivered. Assigned courier only; update authoritative order lifecycle plus delivery timestamp. 200 delivery object plus orderStatus. Input status is NOT a stored Delivery.status field.
- GET /api/v1/orders/{orderId}/status: owning customer; 200 data {orderId,status,updatedAt}.
- GET /api/v1/orders/{orderId}/events: owning customer; 200 text/event-stream; order.status event contains {orderId,status,updatedAt}. Send current snapshot on connect/reconnect, then committed updates; historical replay and GPS are out of scope. Client stops subscribing at terminal state. SSE fits one-way server-to-client status updates; user actions remain HTTP. Reads are idempotent.
- POST /api/v1/orders/{orderId}/review: rating required integer 1–5; comment optional string. Owning customer, delivered, no existing review. 201, Location, data {id,orderId,rating,comment,createdAt}; absent comment returns null. 409 undelivered/duplicate, 422 bad fields.

Supporting routes to finish:
- GET /api/v1/restaurants/{restaurantId}/menu: limit default 20/max 100, offset default 0; available boolean filter; sort name|priceMinor and order asc|desc, stable id tie-breaker; exclude deleted items.
- POST /api/v1/restaurants/{restaurantId}/menu: owning restaurant; name, priceMinor, currency required; description optional; isAvailable defaults true; 201 resource + Location.
- PATCH /api/v1/restaurants/{restaurantId}/menu/{menuItemId}: owning restaurant; allow ONLY name, description, priceMinor, currency, isAvailable. Do not say "any field except restaurantId"; ids, references and timestamps are not client-writable. 200 resource.
- DELETE same item path: owning restaurant; soft deletion, 204 WITH NO BODY. Do not invent a sixth JSON response for this route.
- GET /api/v1/restaurants/{restaurantId}/orders: owning restaurant; status list filter; sort createdAt/default desc; paginated lean rows.
- GET /api/v1/deliveries/available: courier; returns eligible unassigned ORDERS, not fabricated Delivery rows; oldest first, paginated. Document data shape clearly.

Choose and document any still-unspecified filter/sort defaults and label them as completion decisions. Every list needs its own allowed parameters, types/defaults, response example, and validation rules. Use the shared list envelope. Oversized positive limits clamp to 100; negative offsets/invalid sort inputs return 400.

Audit supported basic operations on each entity: include restaurant discovery, order detail, and reads needed by Location headers (delivery/review). Use nested reads where appropriate. Explicitly state unsupported operations, rather than inventing unrestricted CRUD for financial/operational records or adding onboarding systems. No requirement says there must be exactly five endpoints.

## Evidence already recorded — preserve and label accurately

PGlite PostgreSQL 18.3 / PGlite 0.5.8:
- migration.sql and seed.sql ran successfully.
- Seed includes 1,200 orders, 1,200 order items, 1,141 deliveries and 380 reviews.
- Five representative action queries returned data; mutation-related queries are eligibility/read queries, not implemented API handlers.
- evidence/query-plans.txt shows restaurant_orders and assignable_orders used without forcing index scans.
- evidence/invalid-inserts.txt records three actual rejections: order_item_quantity_check, review_requires_delivered_order, one_active_delivery_per_courier.
- evidence/additional-checks.txt records empty-order rejection, total mismatch, forbidden transition, immutable review reference, and historical price preservation.

Run npm ci then npm test to reproduce in a fresh in-memory database. The runner overwrites its PGlite evidence; save native/Neon results under distinct names. SQL migration and seed target a NEW EMPTY database; do not rerun them blindly into a populated one. Never run proof scripts against production.

## Remaining work — execute when asked to finish the handoff

### 1. Finish documentation, not placeholder notes

Create DESIGN.md as the authoritative Steps 1–4 document using this file and actual SQL. README should be a short entry point linking the design, setup, test commands and evidence. Do not append completed contracts under a heading still calling them missing. Include five JSON supporting response examples and the menu DELETE 204/no-body example, with complete list contracts and applicable errors.

### 2. Complete REST versus GraphQL comparison

Show an illustrative oversized REST restaurant-orders response containing the same selected facts as the GraphQL version plus unnecessary nested items/menu descriptions/availability. Show the client's need, the actual GraphQL query, AND its matching hypothetical JSON response. Do not claim the illustrative response came from a running API. Keep currency alongside displayed totals.

Verdict: use REST for this fixed MVP. A lean list plus detail/optional ?expand=items or field selection can address payload needs; REST is not strictly all-or-nothing. GraphQL might help when multiple clients need materially different nested data shapes; user count alone is not a switch threshold. Explain resolver/authorization/query-cost/N+1 tradeoffs briefly. GraphQL does not automatically remove server-side query complexity. Include the SSE analysis from the baseline above.

### 3. Neon concurrency proof

User requests a NEW isolated Neon project/database. Inspect available account access; do not assume a connector exists or that another repo's credentials can be reused. Do not modify existing projects or incur charges without approval. If access is unavailable, finish the test script/docs and report the exact blocker; do not fabricate a result.

Before creating credentials locally, add .env/.env.* to .gitignore with an exception for .env.example. Store actual DATABASE_URL/DIRECT_URL only in ignored local configuration. Commit placeholder .env.example. DATABASE_URL may be pooled; DIRECT_URL must be the direct endpoint for stable two-session testing and migrations. Never print credentials, include them in evidence/ZIP, or paste them into documentation.

Apply migration.sql and seed.sql once to the new empty database. Write a small repeatable test with two independent connections, explicit transactions and READ COMMITTED. Use an available courier and two eligible unassigned orders. Test fixture identities must be recorded without secrets; generate fresh eligible fixtures per run if necessary.

Coordinate actual overlap: transaction A inserts an assignment and keeps its transaction open; transaction B starts a competing assignment to the same courier/different order while A holds the lock. Verify blocking where practical, then commit A. B must fail with the specific one_active_delivery_per_courier check violation, not a timeout or duplicate-order constraint. Roll back B and query final state to confirm exactly one active assignment. Bound waits so test failures don't hang. Also run the opposite launch order if useful; no stress-testing project is required.

Save command context, PostgreSQL version, connection/isolation setup, both outcomes, and final-state assertion to evidence/concurrency-test.txt, with secrets redacted. If it fails, make the smallest justified fix and rerun the relevant checks. Never remove the lock just to make a test finish.

### 4. Diagrams, screenshots, validation and handoff

Export the existing diagram definitions to actual SVG/PNG files and embed them using relative paths in DESIGN.md. Preserve originals and inspect exports for missing labels/fields/cardinalities. No redesigned visual system is needed.

Screenshots of the three database violations remain required. The previous environment blocked native server shared memory, headless browser startup, and in-app local-file viewing. Those are environmental restrictions, not evidence of a schema defect. Respect any active security denial; do not bypass it. The user will capture rejection screenshots manually if needed. Do not retry the previously blocked screenshot workflow as part of this handoff without a new authorised environment. Text logs and constraint-results.html are real evidence but are NOT screenshots.

After schema/script changes, run the relevant checks; for documentation-only changes, verify consistency/links without unnecessary reruns. Update README with tested results and outstanding items. If producing an updated ZIP, exclude node_modules, .env credentials, local database directories, previous ZIPs, and unrelated files.

Final handoff checklist:
- [ ] DESIGN.md has complete Steps 1–4, concrete examples, image diagrams, and traceable decisions.
- [ ] README links the design and explains setup/tests/evidence accurately.
- [ ] Neon two-connection test passed, or is clearly marked blocked/unverified.
- [ ] Required rejection screenshots exist, or are explicitly assigned to the user as pending.
- [ ] No secrets are included in files or archive.
- [ ] Existing proof checks remain passing after any code changes.
- [ ] Repository/public-post status is stated honestly; neither is silently published.
