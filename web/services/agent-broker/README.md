# Agent broker

The broker is the durable, provider-neutral seam between a coordinator and a
remote host. It stores one row per logical effect and an append-only receipt
journal for replay. `effectKey` is unique inside `tenantId`; retries reuse that
pair and cannot create a second job. `sourceSha` and `scopeRevision` bind the
effect to the caller's source and authorization scope.

A host claims a job with a short lease. Every claim increments
`leaseGeneration` and returns a fresh `leaseToken`. Completion and failure must
present both values while the lease is live. An expired lease can be reclaimed
by another host, and the generation fence rejects receipts from the previous
host. Host classes are opaque strings: Huge Blue, Freestyle, and future
transports use the same contract without provider code in this service.

The repository API is in `repository.ts`:

- `enqueueJob` atomically inserts or replays a job by effect key.
- `claimJob` atomically claims the oldest queued/expired job, optionally by host class.
- `renewJobLease` extends a live lease.
- `completeJob` / `failJob` append terminal receipts under the lease fence.
- `listJobReceipts` replays the durable journal from a sequence cursor.
