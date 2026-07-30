# Connectivity v2 implementation notes

## Initial plan

- Build one development-ready backend authority for registration, revisioned discovery, relay policy, and revocation.
- Build one shared Swift connectivity service around a single Iroh endpoint per process.
- Give each remote device one peer-session owner for dialing, admission, application streams, closure, and retry.
- Make RPC, event, terminal, and artifact channels children of the peer session.
- Project immutable connectivity snapshots into Mac and iOS presentation state.
- Migrate both applications, remove superseded lifecycle owners, then verify the complete path on Mac, Simulator, and iPhone.

## Implementation notes

1. Expected: Reimplement every existing transport file.
   Found: Pure wire codecs, cryptographic validation, and the Iroh fork fixes have independent behavioral coverage and do not own application lifecycle.
   Decision: Preserve these audited primitives. Replace endpoint, peer-session, retry, discovery, and application-channel orchestration.

2. Expected: Route discovery could be implemented as transient publication.
   Found: iOS suspension makes continuous subscription delivery non-authoritative.
   Decision: Persist a monotonic account revision in the backend. Publication carries invalidations, while clients reconcile from signed snapshots after launch, foregrounding, and every observed revision.

3. Expected: Compatibility could be decided after the new path worked.
   Found: Mac and iOS releases can be upgraded at different times.
   Decision: Preserve the accepted wire version during migration. Keep legacy Tailscale ingress as a bounded adapter until the supported-version floor permits removal.

4. Expected: Connectivity v2 needed a new push service before route reconciliation could work.
   Found: The existing presence Durable Object already provides account-scoped WebSocket and server-sent-event publication plus directed device nudges.
   Decision: Reuse presence as the best-effort invalidation adapter. Keep the database-backed connectivity authority as the source of truth.

5. Expected: The revision migration could be exercised against the local PostgreSQL stack immediately.
   Found: The shared Docker daemon has several pre-existing, day-old Compose calls stuck while starting services. The focused database test could not reach PostgreSQL.
   Decision: Leave the shared daemon untouched. Keep the schema consistency check and unit tests as the local gate, then run the database behavior test in CI or after the daemon recovers.

6. Expected: A new client engine needed to replace the audited admission and stream implementation.
   Found: `CmxIrohClientSession` already confines one admitted QUIC connection, verifies peer identity, completes admission, and opens typed application lanes without owning app lifecycle or retry policy.
   Decision: Keep it as the connection primitive. `CmxConnectivityEngine` now owns the endpoint and one persistent `CmxConnectivityPeerSession` actor per remote device; the peer actor owns dial coalescing, exclusive control framing, application lanes, closure attribution, invalidation, and redial.

7. Expected: Endpoint activation and route synchronization could publish independent state.
   Found: Publishing an active endpoint before policy installation creates a window where callers can dial with stale authority.
   Decision: Connectivity v2 remains in `starting` through backend reconciliation and atomic snapshot installation. Endpoint replacement uses the same barrier before the replacement generation becomes active.

## Current state

- Done: Current backend, Mac, iOS, shared transport, and recent Iroh-fork fixes mapped.
- Done: Ownership root cause and replacement architecture selected.
- Done: Isolated `feat-connectivity-v2` worktree created from current `main`; development tag `irohv2` reserved.
- Done: Added monotonic account route revisions, a versioned connectivity sync authority, bounded authenticated routing, and focused behavior coverage.
- Verified: Connectivity authority and existing Iroh broker tests pass, web typechecking passes, the generated database schema matches the checked-in migration, and the diff has no whitespace errors.
- Done: Added the matching Swift authority client and strict revision envelope validation.
- Done: Added the shared endpoint engine, peer-session actor, immutable snapshots, and engine-backed RPC transport adapter.
- Verified: Swift authority tests, peer ownership tests, and endpoint/reconciliation lifecycle tests pass.
- Open: Application composition integration, legacy deletion, database behavior execution, and end-to-end verification.
- Next: Replace iOS and Mac runtime composition ownership with the connectivity engine.
