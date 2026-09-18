# Transport v3 status

This workspace is a new Rust/libp2p transport with Stack-authenticated, server-side Cedar authorization, multi-tenant PostgreSQL state, explicit finite or until-revoked offline leases, direct libp2p paths with relay fallback, and browser interop. It has no legacy wire compatibility.

The authority signs grants. Devices and relays verify them locally. A grant binds team, source peer, destination peer, action, policy revision, lease and issue time. Finite leases expire from the authority's last verified timestamp. `until_revoked` is explicit and requires a Cedar `offline_unlimited` decision. Known policy revisions or device revocations invalidate both finite and unlimited grants.

The session protocol is `/cmux/transport/3/session`. It bounds the hello to 16 KiB, data frames to 64 KiB and queues to eight frames. Lanes are control, events, terminal read, terminal input, artifact and simulator. Every application frame has a sequence number. Duplicate frames are acknowledged without re-delivery, gaps fail closed, and acknowledged sends wait for peer queue admission. A receiver-acknowledged renewal never rolls a grant backward and blocked reads/writes are cancelled at expiry or revocation.

The relay uses a small in-org libp2p fork for source/destination admission, direct-connection preference and closed-sender cleanup. Relay management is loopback-only, protected by a per-node token. Containers use immutable image digests, a managed ACR pull identity, read-only roots, dropped capabilities, no-new-privileges and bounded CPU, memory and process counts. Drain refuses new reservations and circuits and exits only after circuits reach zero; clean exit is not restarted.

The HTTP control service verifies Stack user and team membership, device proof-of-possession, admin mutations and destination membership. PostgreSQL serializes team authorization and policy changes. Device enrollment stores validated multiaddrs. Event storage has a global cursor for relay fetches and a team-local cursor for signed revocation ordering. A relay registration endpoint is restricted to a configured operator team and stores only a feed-token hash.

Swift has generated UniFFI bindings, a native endpoint owner, HTTPS-only Stack grant/proof requests, Keychain identity storage, asynchronous v3 enrollment, lane adapters, replay cursors and server-configured renewal scheduling. The iOS composition can project the authenticated directory into v3 routes. The Mac now has an explicit `CMUX_V3_HOST=1` staged host owner with Keychain identity, Stack enrollment, directory publication and native control-lane admission. The production composition still defaults to IRX/iroh, and v3 event/application lane handlers, final switching and iroh removal are outstanding.

Relay circuit addresses are operator configuration (`CMUX_V3_RELAY_ADDRESSES`). Devices enroll once for direct hints, obtain server-issued `relay_reserve` grants, reserve each configured relay and publish target-complete `/p2p-circuit` hints. No relay address is accepted from untrusted discovery data.

## Verified evidence

- Rust workspace: full tests pass, including Cedar policy tests, grant expiry/revocation tests, native FFI duplex/cancellation tests, relay process/drain tests, three connectivity tests and six session tests. Strict workspace Clippy passes.
- Explicit disposable PostgreSQL test passes with migrations through `0003_device_addresses.sql`, covering enrollment replay, tenant isolation, concurrent policy mutation, unlimited access and revocation.
- Chromium WebSocket interop passes through a Rust relay and rejects an invalid grant. `npm ci` reports zero vulnerabilities for the browser fixture.
- Swift `CmuxV3Transport` tests pass with real generated Rust bindings and loopback QUIC. Controller job `8a416b866db3f27beab51286` built the full macOS/iOS/simulator XCFramework and passed Swift v3 tests, Rust tests and strict Clippy. The iOS `cmuxFeature` target also type-checks for `arm64-apple-ios17.0`; full app archive and device runtime remain unverified.
- Azure ACR run `ca7` built `cmuxv3relaystaging.azurecr.io/relay@sha256:e9cb8ee2e471afc01a0b810cdcb07f959f1a764f5e4f8f0b7848686408e9846d` from the current relay source. Generation `g0917e` is installed in East US and West US 2. Both nodes report readiness and feed health, and authenticated TCP, QUIC and WSS probes each transfer 160 messages and 327680 application bytes per direction while rejecting a forged grant and acknowledging renewal.
- The control image `cmuxv3relaystaging.azurecr.io/control@sha256:ef8225d4783c5e5119050fc80ef786751a8c34858fa76d7f5391214e88469689` builds successfully and materializes the signer seed from a protected secret environment variable into a mode-0600 file. It is not deployed because the staging operator Stack team and secret bindings still need to be configured.
- The controller can now provision both native artifacts and compile the full macOS target through Swift compilation. Final linking still fails while iroh and v3 Rust runtimes are linked together because both define `_rust_eh_personality`; this confirms the remaining replacement work must remove iroh from the final app link rather than add a linker workaround.
- v3 FFI packaging now uses a dynamic framework XCFramework to isolate its Rust runtime. Local macOS Swift package tests pass against that framework. A full app relink is pending after controller maintenance ends.
- Generation `g0917c` and then `g0917d` were drained after replacement readiness. Old nodes exited with code zero and remain stopped. A live application probe completed during the East `g0917c` drain, but the relay circuit gauge was zero at that observation, so this is process-level overlap evidence, not proof of an already-established circuit handover.
- Generations `g0916a`, `g0917b` and `g0917d` are now drained and their six staging VMs are deallocated. Their resources remain available for rollback; `g0917e` is the only running serving generation.
- Azure Monitor receives allowlisted private snapshots. Health, stalled drain, resource pressure and revocation-feed alerts are installed for `g0917e`. A real telemetry outage fired and resolved a health alert while relay traffic continued. No notification action group is configured.

## Remaining before replacement

- The additive v3 migrations through `0003_device_addresses.sql` were applied to the PlanetScale `cmux-prod` staging branch and verified with the explicit database test. Deploy the Rust control service and configure relay feed tokens through the operator-team registration flow. No production branch schema write has been made.
- Migrate the staged Mac host's event, terminal, artifact and simulator lane handlers, then switch iOS and Mac composition roots to v3. Exercise login, enrollment, directory, all lanes, renewal, revocation, reconnect and sign-out on an iPhone and Mac.
- Add application event replay and terminal input execution acknowledgements on top of the sequenced lane primitive. Prove session handover with a non-empty relay circuit and replayed data while draining an old generation.
- Add per-team circuit/byte quotas, byte and latency histograms, synthetic authenticated probes, notification routing and certificate-expiry checks.
- Run real NAT/DCUtR, blocked-UDP, network-change, suspended-app, cross-region and offline-revocation tests. Direct paths are composed but not proven by the current loopback and relay tests.
- Finish the threat model and security audit, including database TLS/roles, operator identity, relay feed rotation, secret handling, resource exhaustion, replay/gap behavior and deployed NSG/TLS configuration.

`services/transport-v3/ops/azure/README.md` is the operator runbook. `upgrade.py` is non-destructive: it requires overlapping generations, rechecks replacement readiness, drains one old node at a time and never deletes or force-kills a VM.
