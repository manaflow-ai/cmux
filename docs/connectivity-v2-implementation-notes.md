# Connectivity v2 implementation notes

> **Note (2026-08-25):** the iroh transport was removed from cmux; TCP over
> Tailscale is the only remaining Mac-to-phone connectivity path. Mentions of
> iroh below are historical and no longer describe shipping code.

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

4. Expected: The existing device-directed presence nudge could publish route changes.
   Found: It was team-scoped, wired only on Mac, and no backend mutation published into it. Personal Iroh authority can span devices with different selected teams.
   Decision: Replace it with a separate Durable Object named from the verified Stack user. Both Mac and iPhone use one shared revision-only subscriber. The database-backed connectivity authority remains the source of truth.

5. Expected: The revision migration could be exercised against the local PostgreSQL stack immediately.
   Found: The shared Docker daemon has several pre-existing, day-old Compose calls stuck while starting services. The focused database test could not reach PostgreSQL.
   Decision: Leave the shared daemon untouched. Keep the schema consistency check and unit tests as the local gate, then run the database behavior test in CI or after the daemon recovers.

6. Expected: A new client engine needed to replace the audited admission and stream implementation.
   Found: `CmxIrohClientSession` already confines one admitted QUIC connection, verifies peer identity, completes admission, and opens typed application lanes without owning app lifecycle or retry policy.
   Decision: Keep it as the connection primitive. `CmxConnectivityEngine` now owns the endpoint and one persistent `CmxConnectivityPeerSession` actor per remote device; the peer actor owns dial coalescing, exclusive control framing, application lanes, closure attribution, invalidation, and redial.

7. Expected: Endpoint activation and route synchronization could publish independent state.
   Found: Publishing an active endpoint before policy installation creates a window where callers can dial with stale authority.
   Decision: Connectivity v2 remains in `starting` through backend reconciliation and atomic snapshot installation. Endpoint replacement uses the same barrier before the replacement generation becomes active.

8. Expected: The Mac accept loop could continue recovering the shared endpoint directly.
   Found: Its error path called `ensureHealthy()` independently, so an incoming connection failure could replace the endpoint outside the process lifecycle owner.
   Decision: The endpoint server receives an engine-owned recovery closure. Both outgoing dials and incoming accepts now serialize endpoint recovery through `CmxConnectivityEngine`.

9. Expected: Replacing the session pool with a smaller peer actor made its old cancellation machinery unnecessary.
   Found: Native or test endpoints may return after cancellation, and a replacement dial can otherwise race the retired admission on the host.
   Decision: Each peer actor drains cancelled dials before redialing, uses a bounded deadman for non-cooperative implementations, retries one dead-on-arrival connection, queues control handoff, and closes the old control framing before granting the next owner.

10. Expected: Connectivity v2 could omit the pool's diagnostic integration during migration.
    Found: That would remove path events, close attribution, session-purpose changes, and stable connection correlation from release diagnostics.
    Decision: The peer actor records the same lifecycle and path evidence under one diagnostic session identifier, and the engine-backed control transport forwards precise read, write, and owner-release reasons.

11. Expected: A pushed route revision should reuse the scheduled registration refresh.
    Found: That would perform a server mutation merely because another device changed, and could re-enter newest-wins binding replacement.
    Decision: Mac and iPhone now perform a read-only v2 sync, validate their local binding, install the full policy snapshot, persist it, then retire sessions from the older revision.

12. Expected: The old direct byte transport and session pool might remain as compatibility adapters.
    Found: Production no longer referenced either owner after the connectivity engine migration.
    Decision: Delete the direct transport, pool, pooled adapter, and their factory modes. The app-root facade only defers to the active engine and owns no endpoint, dial, session, or retry state.

13. Expected: Sharing an in-flight revision fetch was sufficient coalescing.
    Found: A newer invalidation could join an older fetch and return after only the older revision was installed.
    Decision: The iOS runtime retains the greatest pending revision and performs a follow-up authoritative fetch before any joined caller for that revision returns.

14. Expected: The Mac connectivity subscriber could share the presence heartbeat enablement gate.
    Found: A user can disable team-presence publication while authenticated Iroh remains active, which would silently disable route invalidation only on Mac.
    Decision: Connectivity subscription follows authenticated account and service URL lifecycle independently. The heartbeat privacy setting continues to control only team-presence publication.

15. Expected: A verified user token was sufficient authentication for invalidation publication.
    Found: Native clients hold that token and could publish an impossible high revision, forcing every device on the account into terminal reconciliation.
    Decision: Publication additionally requires an exact server-only capability shared by the web backend and worker. Subscriptions remain authenticated only by account access tokens.

16. Expected: Cancelling a subscriber task prevented all later delivery.
    Found: A frame already returned by `receive()` could cross an account stop/start boundary before cancellation was observed.
    Decision: `stop()` now awaits stream termination, and the receive loop checks cancellation immediately before invoking the revision handler.

17. Expected: An optional Swift revision would encode the initial connectivity sync as JSON `null`.
    Found: Synthesized `Encodable` omitted the nil field, so the strict v2 backend rejected every first sync after registration and the Mac correctly tore down its unpublished endpoint.
    Decision: Encode `known_revision` explicitly as either an integer or `null`, and cover the exact initial wire body.

18. Expected: A local backend without the private relay JWT signer could still serve direct and LAN development.
    Found: The relay bootstrap route returned `503` before serving its available staging-signed policy, even though local and preview runtimes are intentionally credential-free.
    Decision: Local and preview runtimes return the signed policy without relay credentials so clients use direct and LAN paths. Every deployed non-preview runtime still fails closed when its private relay signer is absent.

19. Expected: Restoring a verified cached host policy also restored the Mac's app-visible Iroh route.
    Found: The host runtime activated and admitted peers from the signed cache, but route publication was coupled to the fresh-registration persistence callback. Every cached startup therefore exposed only legacy routes until another registration succeeded.
    Decision: Give active-route publication its own runtime callback. Fresh policy publishes broker-validated hints, while cached policy publishes the attested endpoint identity without stale hints; persistence remains exclusive to fresh broker responses.

20. Expected: Validating Bonjour aliases after resolving them was sufficient because unknown records could not authorize a path.
    Found: The synchronous DNS callback entered a bounded queue before validation. Hundreds of unrelated cmux development builds could fill that queue and drop the exact authenticated Mac alias without ever bypassing cryptographic authorization.
    Decision: Derive the three accepted rotating aliases from the broker-authenticated binding before browsing, filter every DNS callback against that allowlist before it enters the bounded queue, restart browsing when the allowlist changes, and fence browser startup to the current network lifecycle revision.

21. Expected: Refreshing the signed relay policy before endpoint startup was cheap enough to remain a readiness barrier.
    Found: Clean traces spent 551 ms on Mac and 627 ms on iPhone in that broker call before endpoint activation, even though normal mode permits direct paths.
    Decision: Restore the verified local relay policy before binding and refresh it immediately after activation. Relay-only verification retains the live readiness barrier.

22. Expected: Registration followed by connectivity sync was the minimum authenticated startup sequence.
    Found: Registration already commits the binding before returning, so the following sync repeated an account snapshot read and paid another client round trip.
    Decision: Return the authoritative post-registration discovery snapshot in the registration response. New clients consume it after checking its revision, route contract, relay fleet, and exact local tuple; older brokers and clients keep the separate-sync fallback.

23. Expected: Repeat iOS startup still had to register after the endpoint finished binding because registration publishes its address.
    Found: A previously verified binding can authenticate a read-only connectivity snapshot independently of the new endpoint address, while binding and broker latency are also independent.
    Decision: When persisted metadata exactly matches the current account, device, app instance, tag, endpoint identity, and generation, fetch one authenticated snapshot concurrently with endpoint binding. Admit it only when the snapshot contains exactly one full local expectation match with the same binding metadata, become active from that snapshot, then refresh the signed registration in the background.

24. Expected: The existing authoritative-discovery helper could serve the concurrent startup fetch.
    Found: It mutates actor-owned authoritative state, so a cancelled startup could publish a late response after teardown.
    Decision: Give startup a read-only prefetch helper. Only the still-current lifecycle installs its returned snapshot.

## Current state

- Done: Current backend, Mac, iOS, shared transport, and recent Iroh-fork fixes mapped.
- Done: Ownership root cause and replacement architecture selected.
- Done: Isolated `feat-connectivity-v2` worktree created from current `main`; development tag `irohv2` reserved.
- Done: Added monotonic account route revisions, a versioned connectivity sync authority, bounded authenticated routing, and focused behavior coverage.
- Verified: Connectivity authority and existing Iroh broker tests pass, web typechecking passes, the generated database schema matches the checked-in migration, and the diff has no whitespace errors.
- Done: Added the matching Swift authority client and strict revision envelope validation.
- Done: Added the shared endpoint engine, peer-session actor, immutable snapshots, and engine-backed RPC transport adapter.
- Done: Routed the iOS client runtime and Mac host runtime through the shared engine for endpoint lifecycle, relay mutation, network changes, registration address reads, and route-revision installation.
- Done: Routed Mac accept-loop recovery through the engine and retained bounded admission ownership in the server.
- Done: Ported cancelled-dial draining, dead-on-arrival redial, queued control handoff, application-lane retry, and diagnostic correlation into the peer actor.
- Done: Added an account-scoped revision invalidation channel, backend publication after committed register/revoke mutations, and the same bounded WebSocket subscriber on Mac and iPhone.
- Done: Added read-only pushed-revision reconciliation on both Apple runtimes and coverage proving it does not re-register or refetch obsolete revisions.
- Done: Deleted the superseded direct byte transport, session pool, pooled adapter, device-directed nudge protocol, and obsolete tests after porting their ownership and cancellation guarantees.
- Verified: Worker typechecking and all 179 worker tests pass. All 19 backend publication boundary tests, Swift invalidation-wire, client reconciliation, host reconciliation, and peer ownership tests pass.
- Verified: The full shared transport regression run passes all 489 tests across 61 suites, including newest-revision coalescing, authenticated LAN ingress filtering, and stale-browser lifecycle fencing.
- Verified: All 36 PostgreSQL Iroh behavior tests pass against an isolated native database with the complete migration chain.
- Done: The development backend runs on an isolated native PostgreSQL cluster, a same-worktree Next server, and an authenticated Worker quick tunnel without touching the wedged shared Docker daemon or shared Cloudflare worker.
- Done: Fixed the first-sync wire mismatch found by the real Mac and local backend integration. The initial v2 request now carries the contract's explicit null revision.
- Done: Made credential-free local and preview backends return their signed relay policy while retaining fail-closed relay credential issuance in deployed runtimes.
- Done: Decoupled active Iroh route publication from fresh-registration persistence so a verified cached-policy restart immediately republishes the endpoint identity.
- Done: Persisted deterministic simulator device identity in the app sandbox while preserving fail-closed Keychain identity on physical devices.
- Done: Filtered LAN route discovery to exact broker-authenticated rotating aliases before bounded DNS ingestion.
- Done: Removed live relay-policy refresh from the normal direct-capable startup path on Mac and iOS while retaining the relay-only readiness barrier.
- Done: Embedded post-registration discovery in the broker response, eliminating the separate startup sync for new clients.
- Done: Overlapped authenticated repeat-launch iOS discovery with endpoint binding and moved signed registration refresh after activation.
- Verified: All 500 shared transport tests across 61 suites pass, including blocked-bind and blocked-registration coverage that proves discovery overlaps binding and registration completes after activation.
- Verified: All 32 focused broker, route, and connectivity-authority web tests pass, and web typechecking passes.
- Verified: The relay-disabled iOS Simulator gate completes an authenticated bidirectional Iroh round trip over a non-relay path.
- Open: Final application build integration and end-to-end Mac, Simulator, and iPhone verification.
- Next: Record final tagged Mac and repeat-launch iPhone timings, verify the isolated simulator and physical-device routes, then update the existing pull request evidence.
