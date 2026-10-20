# Effect Boundaries

Expands the backend TypeScript rules in [../SKILL.md](../SKILL.md) for route handlers, services, and scripts.

## Route handler shape

A handler is a shallow adapter: parse request input, select the Effect program, run it once at the boundary, translate domain errors to HTTP. Workflow sequencing, retries, provider calls, and database updates live outside the handler body. A handler that interleaves parsing, database writes, provider calls, and response construction makes retries and idempotency impossible to audit.

Reading one should immediately answer: what input the route accepts, which Effect program performs the workflow, which typed errors map to expected statuses, and which failures are unexpected defects.

## Service shape

Use an Effect service when a workflow crosses an external boundary or has meaningful failure semantics: provider APIs, database reads/writes, auth and team lookup, payment or quota checks, retry and timeout policy, telemetry and usage recording, idempotency claims.

Model expected failures as typed domain errors named for the business failure. `VmLimitExceeded`, `ProviderCapacityUnavailable`, and `IdempotencyConflict` tell a caller more than a raw `FetchError`.

## Dependency shape

Service dependencies are concrete capabilities declared as layer requirements: database client, provider client, auth/team service, clock or timeout policy, telemetry sink, idempotency repository. Not globals, broad ambient containers, or untyped option bags.

## Plain TypeScript carve-out

Constants, schema declarations, config objects, frontend components, pure formatting helpers, and tiny route glue with no external effects stay plain TypeScript. Effect earns its place where explicit failure, dependency, retry, and cancellation semantics reduce real ambiguity.

## Error mapping

When adding a route, check that invalid input maps to 400 or the existing validation status, auth and entitlement failures map to the existing auth/payment statuses, active-limit and quota failures are explicit, provider unavailability is distinguishable from a defect, and idempotency conflicts return a deterministic response. Never disguise an unexpected defect as an expected user error.
