# Cross-host agent broker contract tests

`mux/packages/brain/tests/cross-host-broker.test.ts` is a deterministic contract
harness for the remote agent broker and the provider-neutral VM host lease
transport. It uses in-memory fakes so it can run in the cmux-next checkout while
the broker service and VM adapters live in separate workspaces.

The production implementations should be able to run the same scenarios through
these operations:

- `enqueueJob({tenantId, effectKey, requestDigest, ownerId, hostClass, sourceSha, scopeRevision, payload})` returns a stable `jobId`; a second enqueue with the same `effectKey` and digest returns the original job with `replayed: true`.
- `claimJob(jobId, {hostId, hostClass}, nowMs, leaseTtlMs)` returns a lease token containing `generation` and `expiresAtMs`. An unexpired lease cannot be claimed by another host. A claim after expiry increments the generation and records the expired attempt.
- `renewJobLease` and completion/failure operations require the exact owner, host class, and generation. Stale or wrong-owner requests fail closed.
- `applyEffect(effectKey, requestDigest, operation)` (or the equivalent broker-side effect ledger) runs an effect once and replays its result for duplicate delivery.
- `listJobReceipts(jobId)` returns append-only receipts with a broker-global monotonic `sequence`, attempt number, lease generation, owner, and host class.
- VM adapters expose provider-neutral `acquire`, `renew`, and `release` requests. The fixture uses `huge-blue-01` and `freestyle-vm-01` identities and keeps the provider field as `huge-blue` or `freestyle-vm`.

The tests cover duplicate delivery across host failover, retry after lease
expiry, stale owner and stale generation rejection, and receipt ordering across
restart. They intentionally avoid live Huge Blue or Freestyle credentials; the
same assertions should be run by an integration suite once both transport
adapters are available.
