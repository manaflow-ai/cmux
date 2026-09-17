# Transport v3 status

This workspace is a new Rust/libp2p transport with Stack-authenticated, server-side Cedar authorization, multi-tenant PostgreSQL state, explicit finite or until-revoked offline leases, direct libp2p paths with relay fallback, and browser interop. It has no legacy wire compatibility.

The authority signs grants. Devices and relays verify them locally. A grant binds team, source peer, destination peer, action, policy revision, lease and issue time. Finite leases expire from the authority's last verified timestamp. `until_revoked` is explicit and requires a Cedar `offline_unlimited` decision. Known policy revisions or device revocations invalidate both finite and unlimited grants.

The session protocol is `/cmux/transport/3/session`. It bounds the hello to 16 KiB, data frames to 64 KiB and queues to eight frames. Lanes are control, events, terminal read, terminal input, artifact and simulator. Every application frame has a sequence number. Duplicate frames are acknowledged without re-delivery, gaps fail closed, and acknowledged sends wait for peer queue admission. A receiver-acknowledged renewal never rolls a grant backward and blocked reads/writes are cancelled at expiry or revocation.

The relay uses a small in-org libp2p fork for source/destination admission, direct-connection preference and closed-sender cleanup. Relay management is loopback-only, protected by a per-node token. Containers use immutable image digests, a managed ACR pull identity, read-only roots, dropped capabilities, no-new-privileges and bounded CPU, memory and process counts. Drain refuses new reservations and circuits and exits only after circuits reach zero; clean exit is not restarted.

The HTTP control service verifies Stack user and team membership, device proof-of-possession, admin mutations and destination membership. PostgreSQL serializes team authorization and policy changes. Device enrollment stores validated multiaddrs. Event storage has a global cursor for relay fetches and a team-local cursor for signed revocation ordering. A relay registration endpoint is restricted to a configured operator team and stores only a feed-token hash.

Swift has generated UniFFI bindings, a native endpoint owner, HTTPS-only Stack grant/proof requests, Keychain identity storage, asynchronous v3 enrollment, lane adapters, replay cursors and server-configured renewal scheduling. The v3 feature package and `cmuxFeature` iOS target compile for `arm64-apple-ios17.0` with the locally available Ghostty artifact. The production app composition still constructs IRX/iroh and the Mac host still uses `MobileHostIrxRuntime`; the final runtime switch, route discovery, host-side v3 service and iroh removal are outstanding.

## Verified evidence

- Rust workspace: full tests pass, including Cedar policy tests, grant expiry/revocation tests, native FFI duplex/cancellation tests, relay process/drain tests, three connectivity tests and six session tests. Strict workspace Clippy passes.
- Explicit disposable PostgreSQL test passes with migrations through `0003_device_addresses.sql`, covering enrollment replay, tenant isolation, concurrent policy mutation, unlimited access and revocation.
- Chromium WebSocket interop passes through a Rust relay and rejects an invalid grant. `npm ci` reports zero vulnerabilities for the browser fixture.
- Swift `CmuxV3Transport` tests pass with real generated Rust bindings and loopback QUIC. The iOS `cmuxFeature` target type-checks for `arm64-apple-ios17.0`; full app archive and device runtime remain unverified.
- Azure ACR run `ca6` built `cmuxv3relaystaging.azurecr.io/relay@sha256:d53f2dda303c7a7afb6c458aba4a840b0e764a8b2a4e59806726d728880ca29c` from the team-local revocation source. Generation `g0917d` is installed in East US and West US 2. Both nodes report readiness, feed metrics are healthy when the optional control feed is disabled, and authenticated TCP, QUIC and WSS probes each transfer 160 messages and 327680 application bytes per direction while rejecting a forged grant and acknowledging renewal.
- Generation `g0917c` was drained after `g0917d` readiness. A live application probe completed while the East node was drained, then both old `g0917c` nodes exited with code zero and remain stopped. The relay circuit gauge was zero at the drain observation, so this is process-level overlap evidence, not proof of an already-established circuit handover.
- Azure Monitor receives allowlisted private snapshots. Health, stalled drain, resource pressure and revocation-feed alerts are installed for `g0917d`. A real telemetry outage fired and resolved a health alert while relay traffic continued. No notification action group is configured.

## Remaining before replacement

- Deploy the Rust control service against the approved PlanetScale branch and configure relay feed tokens through the operator-team registration flow. No production schema write has been made.
- Add v3 host runtime and route directory publication, then switch iOS and Mac composition roots to v3. Exercise login, enrollment, directory, all lanes, renewal, revocation, reconnect and sign-out on an iPhone and Mac.
- Add application event replay and terminal input execution acknowledgements on top of the sequenced lane primitive. Prove session handover with a non-empty relay circuit and replayed data while draining an old generation.
- Add per-team circuit/byte quotas, byte and latency histograms, synthetic authenticated probes, notification routing and certificate-expiry checks.
- Run real NAT/DCUtR, blocked-UDP, network-change, suspended-app, cross-region and offline-revocation tests. Direct paths are composed but not proven by the current loopback and relay tests.
- Finish the threat model and security audit, including database TLS/roles, operator identity, relay feed rotation, secret handling, resource exhaustion, replay/gap behavior and deployed NSG/TLS configuration.

`services/transport-v3/ops/azure/README.md` is the operator runbook. `upgrade.py` is non-destructive: it requires overlapping generations, rechecks replacement readiness, drains one old node at a time and never deletes or force-kills a VM.
