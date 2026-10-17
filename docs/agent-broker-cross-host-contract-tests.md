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

## Runtime/workspace verification receipt

`web/scripts/verify-cross-host-broker.ts` runs the provider-neutral verification
against three configured fixture adapters: Huge Blue, Freestyle, and `mac-mini`.
Each fixture lane covers adapter registration, effect-key replay, host-lease
fencing and expiry takeover, persistent workspace create/replay/suspend/resume/
stop, and run-attempt promotion with a stable attach session. The script prints
one redacted JSON receipt and never includes fixture tokens or provider handles.

Run it from `web/` with:

```sh
bun scripts/verify-cross-host-broker.ts
bun test tests/cross-host-runtime-verification.test.ts
```

The fixture lanes always run. Live Huge Blue or Freestyle lease probes run only
when `CMUX_CROSS_HOST_LIVE=1` and all of the corresponding URL, token, and host
identity variables are set:

- Huge Blue: `HUGE_BLUE_HOST_LEASE_URL`, `HUGE_BLUE_HOST_LEASE_TOKEN` (or
  `HUGE_BLUE_API_TOKEN`), and `HUGE_BLUE_HOST_ID`.
- Freestyle: `FREESTYLE_HOST_LEASE_URL`, `FREESTYLE_HOST_LEASE_TOKEN`, and
  `FREESTYLE_HOST_ID`.

Without those values the report contains explicit `live/skipped` lanes and the
fixture result remains the verification gate. A live probe only acquires and
releases a host lease; workspace lifecycle and promotion continue to use the
fixture lane until a provider workspace SDK is explicitly composed into the
runtime.

## Independently deployed worker slice

`workers/agent-broker` packages the durable job consumer as a separate Bun
process. It shares the PlanetScale PostgreSQL ledger and migration owner with
the web runtime, but provider credentials and SDKs enter only through the
versioned adapter module contract in
`web/services/agent-broker/adapterBoundary.ts`.

Run it with `bun web/scripts/agent-broker-worker.ts`, or build
`workers/agent-broker/Dockerfile` from the repository root. Set
`CMUX_BROKER_ADAPTER_MODULE` to a deployment-provided module exporting
`createAgentBrokerAdapters`; missing or duplicate host adapters fail closed.
