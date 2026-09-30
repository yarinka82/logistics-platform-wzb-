# Add Logistics Platform WZB with a PostgreSQL event store

Shipment commands now replay an immutable event stream, validate transitions, append a new event, and synchronously update a rebuildable projection in one PostgreSQL transaction. The React/TypeScript client exposes business commands, event payloads, projection rebuilding, and historical replay.

The OOP backend separates HTTP controllers, application services, the Shipment aggregate, repository interfaces, PostgreSQL adapters, and a transactional unit of work.

The implementation includes command idempotency, expected-version checks, per-stream row locking, an append-only database trigger, Docker Compose for FastAPI/PostgreSQL, and CI tests.

This file is a prepared PR description, not a hosted GitHub pull request. The distributed repository includes a local `dev` → `main` merge with matching file trees. Uploading the already-merged branches does not create a new PR diff. See README for a hosted review of the initial implementation or for the next `dev` change.
