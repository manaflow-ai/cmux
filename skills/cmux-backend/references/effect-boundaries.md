# Effect Boundaries

This reference expands the backend TypeScript rules for route handlers, services, and scripts.

## Route handler shape

Route handlers should be shallow adapters. They should parse request input, construct or select the required Effect program, run it once at the boundary, and translate domain errors to HTTP responses. Keep workflow sequencing, retries, provider calls, and database updates outside the handler body.

A good handler answers these questions quickly:

- What input does the route accept?
- Which Effect program performs the workflow?
- Which typed errors map to expected HTTP statuses?
- Which failures are unexpected defects?

Avoid route handlers that interleave parsing, database writes, provider calls, and response construction. That shape makes retries and idempotency hard to audit.

## Service shape

Use Effect services when a workflow crosses an external boundary or has meaningful failure semantics:

- provider APIs
- database reads or writes
- auth and team lookup
- payment or quota checks
- retries and timeout policy
- telemetry and usage recording
- idempotency claims

Model expected failures as typed domain errors. Prefer names that describe the business failure, not the transport layer. For example, `VmLimitExceeded`, `ProviderCapacityUnavailable`, or `IdempotencyConflict` is more useful to callers than a raw `FetchError`.

## Dependency shape

Make service dependencies explicit. Do not hide important runtime dependencies behind globals when an Effect service can receive them as layer requirements.

Good dependencies are concrete capabilities:

- database client
- provider client
- auth/team service
- clock or timeout policy
- telemetry sink
- idempotency repository

Bad dependencies are broad ambient containers or untyped option bags that force every workflow to rediscover what it actually needs.

## Plain TypeScript carve-out

Plain TypeScript is fine for data-only code:

- constants
- schema declarations
- config objects
- frontend components
- pure formatting helpers
- tiny route glue with no external effects

The point is not to use Effect everywhere. The point is to use it where explicit failure, dependency, retry, and cancellation semantics reduce real ambiguity.

## Error mapping

Expected domain errors should become clear HTTP responses. Unexpected defects should not be disguised as expected user errors.

When adding a new route, check that:

- invalid input maps to 400 or the existing validation status
- auth and entitlement failures map to the existing auth/payment statuses
- active-limit or quota failures are explicit
- provider unavailability is distinguishable from a defect
- idempotency conflicts return a deterministic response

If a caller needs to retry, the response should make that practical.
