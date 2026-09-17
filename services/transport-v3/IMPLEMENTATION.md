# V3 implementation status

Goal: completely replace the iOS transport and iroh, with Rust client/server,
Stack identity, team ACLs, configurable finite/infinite offline access, native
P2P with relay fallback, future browser support, Azure multi-region deployment,
seamless upgrades, observability, security audit, and real end-to-end proof.

## Accepted design

- Stack remains the login and team identity provider. Device keys identify peers.
- Cedar decisions run server-side. Receiving endpoints enforce signed grants.
- Timing is administrator controlled; selected users/devices may use explicit
  unlimited offline access. Infinite permission has no offline revocation bound.
- Regional relays have explicit addresses and backup reservations. A global API
  discovers them; no anycast session routing or inter-relay mesh initially.
- No legacy compatibility. Application sessions must survive transport reconnects.
- Existing cmux database is PlanetScale Postgres. No database migration or new
  database provider has been selected/deployed for v3 yet.

## Evidence and corrections

- Foundation commit 6c4c577fa3e: 15 Rust tests, Chromium relay interoperability,
  device/simulator target checks, Linux and Apple CI pass. No real NAT evidence.
- Initial production relay draft is incomplete: only transport identity was
  checked, not team relay admission. It must not be deployed in that state.
- Stock libp2p-relay 0.21.1 has no source/destination admission callback. Add a
  minimal hook in manaflow-ai/rust-libp2p, preserving the standard wire protocol.
- Closing listeners and restarting after a fixed delay does not prove seamless
  upgrade. Drain must reject new circuits on existing connections too, retain
  established circuits, and require client session handover before termination.
- Metrics in the first draft double-count renewals and can underflow on closure;
  replace arithmetic estimates with event-owned sets. Protect management access.
- Fork hook implemented at e277dfbd12a6491e1c09befa3651191ab7965893 in
  https://github.com/manaflow-ai/rust-libp2p/pull/1 (author lawrencecchen).
  All 9 relay integration tests pass. Live counts now come directly from relay
  behavior ownership, including pending circuits, rather than duplicate counters.
- Relay now requires public authority keys and private on-disk identity/management
  credentials; cached grants are bound to authenticated source, destination, team
  and action. Missing grants and cross-team circuits are denied by the relay hook.
- Actual server-process test passes: forged grant denied, valid reservation/pair
  accepted, unauthorized drain denied, readiness false during drain, established
  circuit still exchanges application data, clean exit after circuit closes.
- The superseded Azure shell prototypes were moved to HQ task scratch, not
  committed or deployed. They assumed old environment-based keys and timed
  restarts. Production automation still needs
  generation-based provisioning, private management, mounted secrets, public TLS,
  managed registry identity, and drain-to-zero before invocation.
- The supervisor must use restart-on-failure, not restart-always/unless-stopped:
  a clean exit after drain must stay stopped instead of resurrecting the old relay.
- Current workspace verification: 20 Rust tests and strict Clippy pass, including
  the new actual-server process test. Hosted checks on the updated commit and
  real Azure/NAT/iPhone testing remain outstanding.

## Work remaining

- [ ] Authenticated Rust control service, trusted device enrollment and team membership.
- [ ] Persistent state, policy mutation, regional freshness and revocation delivery.
- [ ] Destination-aware relay admission, quotas, draining, TLS and stable identity.
- [ ] Session streams, authorization renewal/expiry, replay, input acknowledgments.
- [ ] Swift bindings and complete iOS/macOS v3 integration; remove iroh path.
- [ ] Azure deployment through CLI, public endpoint and authenticated live E2E.
- [ ] Healthy overlapping generations, canary rollout, safe rollback and draining proof.
- [ ] Collected metrics/logs, alerts, probes, operating/recovery runbook.
- [ ] NAT/blocked-UDP/network-change/suspension/cross-region/revocation E2E matrix.
- [ ] Security audit of code and deployed configuration; address findings.
- [ ] Final requirement-by-requirement evidence audit.

## Control service checkpoint

- Rust HTTP control service now verifies Stack users, team membership, and live
  administrator permission. Member checks cache for 20 seconds per region;
  original verification time bounds finite grants. Admin mutations bypass caches.
- Enrollment derives the PeerId from a domain-separated device proof. Proofs bind
  deployment, Stack user, endpoint, payload, timestamp and one-use UUID. Postgres
  consumes nonces atomically across regions. Clients cannot assign tags or leases.
- Team rows serialize authorization, policy changes, device policy and revocation.
  Optimistic revision checks reject concurrent lost updates. Revocation disables
  the device and records a revision/event in the same transaction. Destination
  owner membership is checked before authorizing that device as a target.
- 24 Rust tests pass plus an explicit disposable-Postgres test covering replay,
  cross-team access, takeover, admin restrictions, concurrent updates and revocation.
  Three Azure script tests pass. iOS device/simulator transport checks pass on
  Rust 1.98.1 after explicitly installing those targets for that toolchain.
- No production/staging database migration was run. The only database used is
  the task-specific temporary PostgreSQL container on the shared dev VM.
- SQLx locks an optional, disabled MySQL/RSA dependency with RUSTSEC-2023-0071.
  ops/audit.py proves RSA is absent from all selected target dependency graphs
  before allowing that one advisory. The paste maintenance warning applies to
  Linux build-time netlink dependencies; the earlier non-runtime-tree statement
  was only true for macOS and is superseded here.
- Azure generation provisioning script creates new nodes instead of restarting
  old ones, uses registry managed identity and immutable image digests, exposes
  no public management/SSH, and mounts private node keys read-only. Deployment,
  client handover, public TLS proof, metrics collection/alerts remain unverified.

## Dependency audit checkpoint

- Added the dependency-audit gate in separate failing commit 2dbb3cef290.
- cargo-audit 0.22.2 found RUSTSEC-2026-0118 and RUSTSEC-2026-0119 in
  Hickory 0.25.2. Fork commit 5e889629590ae4b52a0213a2ab85a28cb1ffeb3b
  upgrades Hickory to 0.26.3 and adapts DNS and mDNS APIs. DNS configuration
  construction now returns errors instead of introducing a new panic.
- After updating the application pin: 20 Rust tests pass, strict Clippy passes,
  dependency audit reports zero vulnerabilities. One maintenance warning remains
  for paste (not in the selected runtime dependency tree).
- Fork DNS tests (2), DNS builder tests (3), and mDNS unit tests (5) pass.
  The mDNS IPv6 integration test fails on this fleet host with unavailable
  interface addresses, identically on the pre-update baseline. V3 does not enable
  mDNS; this is not evidence of working IPv6 transport and must not be hidden.
- The audit is only a dependency checkpoint. Application threat-model review,
  deployment configuration audit, and all final-state E2E requirements remain.

## Azure staging checkpoint

- Created resource group cmux-v3-staging-shared and registry cmuxv3relaystaging
  in subscription a428770c-842f-42b8-b23c-cabe9003b47c. No production resources
  were changed. Staging signer seed and SSH key live in private operator storage.
- ACR run ca1 built source 410f72d2ead26e3829fd794ce8aaa2c64d650c9c. Image:
  cmuxv3relaystaging.azurecr.io/relay@sha256:e9de99f3b238885a1a58a54b66d6ebc0f800f6416f3117df9cf0b508ae04065d
- Imported Caddy 2.11.4 for WSS/TLS. The deployment only transfers public authority
  keys; each VM generates its private node identity and management token locally.
- First VM request failed: Standard_B2s unavailable in eastus. D2as_v5 is also
  restricted for this subscription in eastus and westeurope. Querying the full
  regional SKU inventories before selecting a supported size. No relay VM was
  created by those requests. Network/identity resources are retained for reuse.
- Fixed Azure CLI empty-success JSON handling and cwd-relative dirty-tree check.
  Deployment resumes from the existing image with --built-sha; no rebuild needed.
- Added a live relay probe which generates endpoint keys on the leased host and
  receives short-lived test grants signed on the operator machine. It transfers
  320 KiB each direction and checks forged-grant denial; not yet run on Azure.
- Very short offline leases now request correspondingly fresher Stack evidence.
  Non-local Postgres connections require verified TLS. Neither change is in the
  already-built relay image; the relay binary itself was unchanged.

## Live East US proof

- East US staging node is installed and running on Standard_D2als_v7:
  v3-staging-eastus-g0916a.eastus.cloudapp.azure.com (20.127.94.86), PeerId
  12D3KooWPUivP2Fdq4BnD2hU477MG4X31rEdznqnH1k5GuKNiwUQ.
- TCP 4001, QUIC/UDP 4001, and WSS/TLS 443 each passed a real fleet-to-Azure
  authenticated relay exchange: 160 messages, 327680 application bytes each
  direction, forged grant rejected. TLS certificate/hostname verification stayed
  enabled. These prove relay paths, not direct NAT traversal or iOS behavior.
- Private metrics confirm 6 accepted grants, 3 rejected grants, readiness 1,
  and zero remaining connections/circuits after the probes. Public scans from the
  fleet find SSH 22, management 8080 and internal WebSocket 4002 unreachable;
  public TCP 4001 and TLS 443 are reachable. Receipts are in HQ artifacts under
  transport-v3/azure-staging (g0916a.json, eastus-{tcp,quic,wss}.json, metrics).
- West Europe refused NSG creation because the region is not accepting new
  customers for this subscription. North Europe allowed networking but restricts
  ordinary small VM sizes; no second relay has been created yet. Evaluating
  another supported ordinary VM region without switching to confidential/GPU VMs.
- Cloud-init's historical package error came from azure-cli missing in the
  default Ubuntu repository. Installation now reconciles runtime packages and
  installs CLI from Microsoft's signed repository, then checks actual relay
  readiness. It does not equate VM provisioning or boot history with readiness.

## Two-region relay and monitoring checkpoint

- West US 2 is running on Standard_D2als_v7 at
  v3-staging-westus2-g0916a.westus2.cloudapp.azure.com (20.98.68.177), PeerId
  12D3KooWG61m7sFQi1Q59TmwaGYQCpRR8V1GVm7EjaE787V4wNgP. Same immutable relay
  and proxy digests as East US. TCP, QUIC and WSS each pass the authenticated
  160-message, 327680-byte-each-direction probe, with forged grants denied.
- West US 2 public scans confirm SSH, management and internal WebSocket ports
  are unreachable; relay TCP/TLS are reachable. Unused failed Europe resource
  groups were verified to contain no VMs/data and submitted for cleanup.
- Both regions send allowlisted minute snapshots through Azure Monitor Agent
  into one managed thirty-day Log Analytics workspace. Collection is independent
  of the relay process and needs no relay secrets or Docker socket access.
  Actual central records from both regions show scrape_ok=true and readiness=1.
- Three scheduled queries cover missing/unhealthy reports, stalled drains and
  host memory/disk pressure. Queries were executed successfully before enabling
  the rules; a never-reporting inventory entry returns missing_heartbeat.
  Notification routing is not configured. Stopping East US reporting produced
  a real cmux-v3-health alert at 2026-09-17T06:12:11Z. Reporting was restored
  at 06:13:10Z. Fresh central records from both regions show readiness=1 after
  restoration. Azure subsequently marked the alert Resolved; receipt retained.
- The live relay continues exchanging authenticated QUIC messages while its
  telemetry timer is stopped. This is monitoring isolation evidence, not session
  handover or relay-upgrade proof. Receipts remain in HQ artifacts/transport-v3/
  azure-staging. Seven Python operation tests pass.

## App integration entrypoints inspected

- Current app wiring is IRX over iroh, not just the older CmxIrohClientRuntime:
  ios/cmux/AppCompositionRoot.swift owns MobileIrxRuntimeComposition and
  Sources/Mobile/MobileHostService.swift selects MobileHostIrxRuntime.shared.
- Phone lane methods are in ios/cmuxPackage/Sources/cmuxFeature/
  MobileIrxRuntimeComposition+Streams.swift. They expose control, events,
  terminal output/input, artifacts and simulator streams. All must move to v3;
  replacing only the generic byte factory would leave active iroh dependencies.
- The libp2p fork already contains protocols/stream (libp2p-stream 0.4.0-alpha).
  Pinning it to the same fork revision can supply generic streams without a
  hand-written swarm connection handler. This has only been inspected, not wired.
- No Swift entrypoint has changed. Native session ownership, renewal, replay,
  acknowledged input and revocation must be implemented/tested before the app
  switch and removal of IRX/iroh. Existing probe tests do not cover these contracts.
- Drain currently rejects permission renewals as well as new admissions. Existing
  circuits remain subject to grant expiration. Upgrade work must cover renewal
  during handover and demonstrate continuity across that deadline; the short
  relay-process drain test is insufficient evidence for long-lived sessions.

- Azure alert-query behavior also passed with synthetic healthy, never-reporting,
  stale, failed-scrape, not-ready, draining, disk-pressure and memory-pressure rows.
  check_queries.py runs these cases in the real query engine without ingesting
  records or firing alerts. Both unused Europe resource groups are deleted.
- Disposable PostgreSQL test container and its exact two SSH tunnels are stopped.
  Fleet lease 20260916220258-19123-14679 is released. New Mac workloads now use
  the controller job system following the 2026-09-17 retirement instruction.
  No production database was touched.

- Operator log queries bypass Azure's documented two-minute response cache using
  Cache-Control: no-store. Freshness still depends on ingestion; timestamps are
  checked explicitly. The monitoring drill did not expose any public management
  port, restart a relay, or send notifications to anyone.

## Native application stream checkpoint

- Added /cmux/transport/3/session using libp2p-stream pinned to the same reviewed
  fork revision. It exposes bounded bidirectional lanes and concurrent sender
  handles without a custom libp2p connection handler. Maximum admission is 16 KiB,
  data frame 64 KiB, queues eight frames, with bounded context session capacity.
- Admission binds team, transport-authenticated source/destination and lane
  action. Terminal read/input require terminal_read/terminal_write respectively;
  initiating data on a read lane is rejected at both API and receiving wire path.
- A separate authorization future cancels both stream halves even when a peer
  stops reading or application queues fill. Reads recheck permission before
  returning buffered bytes. Renewal is receiver-acknowledged, cannot roll policy
  revision/issue time backward, and cannot revive expired or revoked sessions.
- Five real QUIC session tests pass: deadline renewal, full-buffer expiry and
  capacity release, unlimited revocation with an offline initiator, malformed/
  oversized/forged headers, and read permission refusing terminal input.
- Drain regression failed before the fix (2030ea063bc) and passes after
  b6180ac5c66. Draining now refreshes only still-live cached permissions while
  continuing to refuse every new HOP circuit/reservation. The real relay-process
  test now carries the application stream itself through renewal past its old
  deadline and verifies clean exit after the encrypted circuit closes.
- 30 Rust tests pass across the workspace/focused additions; strict Clippy and
  Apple device/simulator target checks pass. The unchanged explicit PostgreSQL
  test was not rerun this turn. Application replay, input execution acknowledgment,
  endpoint lifecycle, grant-fetch scheduling and Swift bindings remain incomplete.
- Six live Azure application-stream probes pass, TCP/QUIC/WSS in both regions:
  160 messages and exactly 327680 application bytes each direction, forged grant
  denied and renewal acknowledged. Receipts are {eastus,westus2}-session-*.json
  in HQ artifacts/transport-v3/azure-staging. These are relay paths, not NAT or
  application UI verification. The deployed relay image is still g0916a and does
  not yet contain the drain-renewal fix; that fix has process-test evidence only.
- The default libp2p Identify behaviour emits observed-address candidates, and
  DCUtR consumes those events itself. No extra custom address-promotion logic is
  needed for that mechanism. Real NAT reachability remains to be demonstrated.

## Stream library lifecycle fixes

- Inspection found libp2p-stream retained per-connection senders after disconnect
  and randomly selected between direct and relayed connections for new streams.
  The regression test in fork commit 2bb83150 fails after 100 closed connections.
- Fork ef1f4f3e releases closed sender entries and prefers established direct
  connections for new streams while retaining relay fallback. Existing streams
  are preserved. Final fork pin a996f703a7586a72398ea58dcdd535acc5ae858e also moves
  tests after implementation to satisfy Clippy.
- Two stream unit tests, two integration tests and two doc tests pass. Strict
  Clippy for the changed crate passes with --no-deps. Running it across fork
  dependencies also flags existing conditional identity APIs as unnecessary
  Result/Option wrappers under Ed25519-only features; those public APIs support
  other feature combinations and were not changed. The consuming v3 workspace
  runs strict Clippy across all of its own targets without exclusions.
- Updated dependency audit finds no known selected vulnerability; optional RSA
  remains excluded and paste's Linux build-time maintenance warning remains.
- New-stream preference is not existing-stream migration. The endpoint owner
  still needs explicit route/session handover and replay before old circuits close.

## Swift endpoint integration checkpoint

- Added a Rust endpoint owner, UniFFI 0.31.2 bindings, and a Swift CmxByteTransport
  adapter. The generated API permits simultaneous read/write, explicit per-call
  cancellation, close, permission renewal, and revocation updates. Large writes
  are split into bounded frames under one write lock to prevent interleaving.
- Two native Rust ownership tests and two Swift tests with real loopback QUIC
  passed before the route-factory changes. They cover concurrent connect,
  cancellation, late connection cleanup, and large byte transfer. The broader
  mobile RPC suite stalled and was interrupted; its completion is unverified.
- Typed v3 routes use separate peer and device identities. The factory checks
  the provider's authenticated enrollment binding before dialing, supplies the
  connection permission to relays, and refuses Stack-bearer transport mode.
  No production grant provider or app composition switch is implemented yet.
- Removed an uncommitted placeholder native API. Missing XCFrameworks are build
  errors; setup and iOS build entrypoints now generate the actual artifact. The
  generation script serializes writes and caches by source/settings/content hash.
- The first controller attempt failed before execution because its default
  shell did not support Bash process substitution. Job 78b261551930d1b98fb38905
  explicitly invokes Bash and is building all Apple slices from 2436efaa279.
  Its final test/artifact result is pending. Earlier local Swift test invocations
  did not follow the fleet execution rule; no further local builds are used.
- Added localized libp2p v3 labels to existing diagnostics/settings vocabulary.
  Labels contain no device identifiers. HIG writing page was requested but its
  content required JavaScript; no layout or interaction changes were designed.
