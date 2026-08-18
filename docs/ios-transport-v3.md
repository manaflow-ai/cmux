# iOS transport v3: from-scratch replacement

Status: draft, August 2026. Supersedes `docs/iroh-app-transport-architecture.md` for the client and host transport implementation. The broker web API contract, relay fleet, grant model, and pairing security design carry forward unchanged.

## Why replace instead of repair

Field evidence from August 2026 (five days of device logs, build 2026-08-12): median launch-to-ready 12.7s with p90 at 105s, 11 of 40 launches never ready within 10 minutes; 286 dial failures from dials racing endpoint activation; 79 of 207 recovery attempts failed, 35 of 57 reconnect failures were "superseded by a newer attempt"; connection state flapped 47 times in under 30 seconds while a healthy session was up. The July 2026 design review found the same structurally: recovery ownership is scattered across MobileShellComposite (46k lines, ~29 per-surface dictionaries), a single serialized RPC writer parks all traffic when one send wedges, and the dial ladder keeps retrying on a 2s loop after success.

The transport also carries a custom dependency chain: manaflow forks of iroh core, the noq QUIC NAT-traversal crate, and iroh-ffi, whose fork features (pre-admission candidate deferral, zero initial stream credit, admission barrier, custom stall detection, home-relay credential continuity) each exist to patch a problem the layer above created or to serve an IP-privacy property the product does not claim (`docs/iroh-app-transport-architecture.md` explicitly disclaims peer-IP concealment). The fork multiplies every upgrade and debugging cycle.

v3 rebuilds the transport on stock upstream iroh with a single-owner connection state machine, and reduces the fork surface to zero.

## What stays

- The broker protocol and web API: `/api/devices/iroh/*` registration + challenge, discovery, `/api/relay/token`, presence invalidation pushes. Server code does not change in this program.
- The grant/security model: Ed25519 pair grants bound to device IDs + EndpointIDs, bearer-never-on-unproven-transport, fail-closed policy, 30s revalidation, offline grant cache semantics.
- The managed relay fleet and signed relay policy (catalog, pinned policy keys, endpoint-bound relay JWTs).
- The RPC request/response surface and push topics the upper layers consume (wire compatibility with current Macs is a non-goal for v1 of v3; phone and Mac ship together in dev builds first).

## What is replaced

- The forked dependency chain — `manaflow-ai/iroh-ffi v1.0.2-cmux.7` → `manaflow-ai/iroh @4152d81` (v1.0.2 + 26 commits) + `manaflow-ai/noq` — with stock `n0-computer/iroh-ffi v1.1.0`. The pin appears in exactly one manifest (`Packages/Shared/CmuxIrohTransport/Package.swift` today) and four `Package.resolved` files.
- `CmuxIrohTransport` (29k lines) and the transport-facing parts of `CmuxMobileTransport`, `CmuxMobileRPC` session management, and the dial/recovery orchestration inside `CmuxMobileShell`.
- The Mac host's transport plumbing: `MobileHostIrohRuntime*` composition, the iroh admission/accept path, endpoint hosting, broker registration, relay credential rotation. The serving layer above the seam (`MobileHostService` connection registry, event queue, `TerminalController` RPC router) stays.
- The legacy Tailscale TCP transport becomes a route implementation behind the same seam (route proof retained), not a separate parallel transport stack.

### Fork-feature disposition on stock upstream

| Fork feature | Upstream state | v3 disposition |
| --- | --- | --- |
| Pre-admission candidate deferral, zero stream credit, two-phase admission barrier (noq + iroh + ffi patches) | Never upstream | **Dropped.** Grant check moves to the first control stream; a denied peer is closed. Pre-denial NAT candidates are visible to a peer that already knows our EndpointID; EndpointIDs stay bearer-adjacent secrets. Deletes the largest fork surface and the admission-barrier bug class. |
| `pending_open_paths` dedup + hard cap ([iroh#4390](https://github.com/n0-computer/iroh/issues/4390), still open) | Open | Trigger requires ≥2 connections with persistently failing path opens (typically unreachable explicit hints). v3 stops supplying explicit private hints (in-band discovery only), bounds concurrent connections (foreground + small warm pool), and the endpoint health watchdog recreates a degraded endpoint. Residual risk documented, telemetry on endpoint memory. |
| App-frame-only stall evidence (manaflow-ai/iroh#10) | Not upstream | v3 does not consume FFI path-stall verdicts for teardown decisions. Liveness comes from application-level evidence (RPC responses, lane traffic); QUIC handles loss recovery. |
| Home-relay credential continuity (in-place token replacement) | Not upstream; upstream rotation = `remove_relay` + `insert_relay` (live actor captures token at start) | Make-before-break at our layer: insert a second relay config with the fresh token, confirm home-relay health, then remove the stale one. Sub-second relay blips during rotation are acceptable; direct paths are unaffected. |
| Connect cancellation bindings | Partially upstream (v1.1.0 exposes endpoint close semantics) | Bounded dial attempts run in cancellable tasks; a timed-out dial is abandoned by generation fence even if the FFI call cannot be interrupted, and the endpoint is recreated if abandoned dials accumulate. |
| Failed-rebind driver death ([iroh#4289](https://github.com/n0-computer/iroh/issues/4289), still open) | Open | Same mitigation the fork era used, kept at our layer: endpoint health watchdog recreates the endpoint from the same key (identity generation stable, runtime generation advances). |

## Design principles (each traces to a recorded failure)

1. **One owner per concern.** A single `ConnectionSupervisor` actor per paired Mac owns dial, admission, health, and teardown. Nothing else dials. Triggers (launch, foreground, network change, presence push, manual retry, method change) are *inputs* to the supervisor, classified explicit-vs-automatic; automatic triggers join or are coalesced into the in-flight attempt, never cancel it. (Supersede storm: 35/57 reconnect failures; recovery-owner races.)
2. **Dial only from a ready endpoint.** The supervisor cannot enter `.dialing` until the endpoint layer reports active; endpoint readiness is an awaitable barrier, not a poll. (286 "endpoint unavailable" dial failures.)
3. **Success stops retry.** Retry ladders are owned by the supervisor state machine; entering `.ready` cancels them by construction because the ladder lives inside the `.reconnecting` state. (207 dial failures while a session was up; 2s loop that never stopped.)
4. **Level-triggered rebuild.** Every terminal failure state arms exactly one pending rebuild with bounded decorrelated-jitter backoff (1s floor, 30s foreground cap, seedable RNG); any external wake collapses the wait. No `.failed` state without an owner. (17-hour wedge.)
5. **Rate-limit state outlives connections.** Broker cooldowns (Retry-After, 429 floors) are account-scoped objects above the connection lifecycle. (Retry storm on every reconnect.)
6. **Evidence taxonomy at the auth boundary.** Transient / signed-out / cancelled are three distinct outcomes end to end; `try?` is banned at that boundary; one-shot 401 recovery in the broker client; auth rejection never clears cached route state. (Launch wedge, wake outages.)
7. **Timeouts spanning suspension prove nothing.** Every deadline is epoch-checked against a foreground-resume epoch; a probe that crossed a background window is abandoned without teardown and re-run once. (Foreground teardown churn.)
8. **Data-plane readiness is the only success.** An attempt completes when the terminal/event lanes are subscribed on the new connection generation, not when the dial returns. (Recovery counted done while the session was unusable.)
9. **Generation fencing everywhere.** Connection generation, endpoint runtime generation, and identity generation are distinct monotonic values; every async continuation revalidates its captured generation after each await.
10. **Simplicity is the security posture.** Stock iroh admits a TLS-verified peer before cmux's grant check; the grant check happens on the first control stream before any application lane opens, and a denied peer is closed. We accept that a peer who already knows our EndpointID can observe NAT-traversal candidates pre-denial; that peer is same-account or holds a leaked EndpointID, and EndpointIDs are treated as bearer-adjacent secrets (QR, authenticated registry only). This deletes the entire fork.

## Architecture

One new package, `Packages/Shared/CmuxPeerTransport`, replaces `Packages/Shared/CmuxIrohTransport` for both platforms. Two targets:

- **`CmuxPeerTransportCore`** (no IrohLib import): the state machines and protocol logic — `PeerConnectionSupervisor`, `PeerEndpointReadiness`, `PeerReconnectBackoff`, `PeerBrokerCooldownLedger`, generation fencing, the `CMUXPRT2` lane header codec, admission frames, and the seam protocols the adapters implement (`PeerEndpointProviding`, `PeerConnecting`, `PeerLaneOpening`). Fully unit-testable with fakes.
- **`CmuxPeerTransport`**: the engine — client runtime, host runtime, trust broker client, relay policy verification + credential rotation, admission controller, keychain identity stores, and the IrohLib adapter (`n0-computer/iroh-ffi` exact `v1.1.0`, the only target importing it).

### Consumer seams (unchanged)

The package plugs into the exact seams the current transport occupies, so `MobileCoreRPCClient`, `MobileShellComposite`, `MobileHostConnection`, and the `TerminalController` RPC router do not change their contracts:

- iOS client: `CmxByteTransportFactory` / `CmxRouteAwareByteTransportFactory` registered for `.iroh` in `cmuxApp.swift`; `MobileSyncRuntime.independentEventByteStreamProvider` / `terminalLaneProvider` / `artifactLaneProvider`; `MobileIrohMacDiscovering` / `MobileIrohMacForgetting` / settings hooks implemented by the new composition.
- Mac host: `MobileHostService.acceptTransport(any CmxByteTransport, ...)`, `MobileHostIndependentEventWriting`, the application lane router accept surface, and route publication into `mobile.host.status`.
- Wire above the transport: the 4-byte length-prefixed JSON `MobileSyncFrameCodec` control protocol is unchanged.

### Protocol: `cmux/mobile/2`

New ALPN and lane-header magic (`CMUXPRT2`). Lane model is unchanged in shape (control, serverEvents+cursor, terminal+resourceID+cursor, artifact+resourceID+offset). Admission is single-phase: the client opens the control stream with a header carrying its signed pair grant; the host verifies (signature, binding, expiry, broker revalidation with the same ≤30s cadence and offline-cache semantics as today) and answers one ack frame; denial closes the connection. The two-phase barrier, zero-initial-stream-credit, and deferred-candidate machinery are deleted with the fork.

A new-protocol phone does not iroh-connect to an old-protocol Mac (ALPN mismatch fails in one round trip and marks the route stale); dev builds pair same-tag phone+Mac, and staged rollout ships the Mac first while phones retain the legacy Tailscale TCP route for old Macs. This is the deliberate cost of deleting the fork's admission barrier.

### Connection supervisor

Per-peer single-owner actor with states `idle → waitingForEndpoint → dialing → admitted → ready ⇄ degraded → closed/failed(kind)`. All triggers enter through one `note(trigger:)` funnel; automatic triggers (network change, foreground, presence push, backoff expiry) join or coalesce into the in-flight attempt; only explicit intent (manual retry, connection-method change, sign-out) replaces it. `ready` requires data-plane proof (control stream admitted AND the caller's readiness closure — terminal/event subscription on the new generation). Retry scheduling lives inside `failed`/`degraded` states, so a live session structurally cannot be redialed by a leftover ladder. Every attempt carries a generation; every continuation revalidates after each await.

### Endpoint lifecycle

One endpoint per process, owned by an `PeerEndpointManager` actor: activation barrier (dial paths await `active`, never observe "unavailable"), health watchdog (recreates from the same secret on driver death — upstream #4289 — advancing runtime generation only), relay policy application, and make-before-break relay credential rotation (insert refreshed relay config, confirm home-relay health, remove stale entry).

### What the composite keeps

`MobileShellComposite`'s orchestration (route selection, multi-Mac aggregation, secondary promotion) stays in place and consumes the same seams. The engine-level guarantees remove the triggers of the recorded field pathologies: a dial can no longer race activation, concurrent dials to one peer coalesce inside the supervisor instead of superseding each other, and success cancels retries by construction. Deeper composite simplification is follow-up work on top of this base.

### Explicitly deferred (documented, not silently dropped)

- Bonjour/LAN bootstrap (authenticated rendezvous aliases): follow-up; relay + direct + in-band discovered LAN candidates cover the launch path.
- Offline first-pair (QR attestations): follow-up; online pairing and offline *re*-connect via cached grants are in scope.
- Custom relay UI plumbing: the settings surface stays; custom relay entries ride the same `RelayConfig` path.

## Dependency base

Stock upstream, zero forks: `https://github.com/n0-computer/iroh-ffi` pinned to the exact `v1.1.0` release (wraps iroh core 1.0.x including iroh-relay). SPM consumers get the release-attached, checksum-pinned `IrohLib.xcframework.zip`; no local Rust toolchain, no fork CI, no binary hosting on our side. Verified against cmux requirements: `RelayConfig.auth_token` sends the endpoint-bound relay JWT as `Authorization: Bearer` on the relay websocket upgrade; `RelayMap.insert`/`remove` plus `Endpoint.insert_relay` support credential rotation (rotation = remove then insert, since a live relay actor captures its token at start); `RelayMode.custom(map:)` plus the `Minimal` preset keep n0 defaults and public DNS discovery out of production; custom accept exists for the host side. The clean-room `iroh-testbed` (July 2026) already proved this API shape end to end over the cmux relay fleet on iOS Simulator and a physical iPhone.

Only the transport package imports `IrohLib` (recorded lesson: an app target importing IrohLib without linking it builds locally and fails on hosted builds).

## Migration and teardown plan

Single-branch replacement (`iroh-scratch-claude`), no dual-stack period in the codebase:

1. `CmuxPeerTransportCore` lands with its full behavior test suite (state machine, backoff, cooldown, fencing, codecs).
2. `CmuxPeerTransport` engine lands: broker client, relay policy, admission, identity stores, IrohLib v1.1.0 adapter.
3. Host integration: `MobileHostPeerRuntime` replaces `MobileHostIrohRuntime*` in `Sources/Mobile`; conformances for `CmxByteTransport`, `MobileHostIndependentEventWriting`, and the lane-router accept surface.
4. Client integration: `MobilePeerRuntimeComposition` replaces `MobileIrohRuntimeComposition` in `ios/cmuxPackage`; same seam conformances (`transportFactory`, lane providers, discovery/forget/settings hooks).
5. Teardown: delete `Packages/Shared/CmuxIrohTransport`, drop the `manaflow-ai/iroh-ffi` pin from every manifest and `Package.resolved`, update the xcodeproj/workspace package references, and retarget the iroh release-gate scripts at the new package or retire them explicitly.
6. Persistence continuity: the endpoint secret keychain item, device-identity item, paired-Mac SQLite store, and grant cache formats are readable by the new engine (same services/keys), so existing pairings survive the swap; the broker binding re-registers in place per the (user, device, tag) slot contract.

## Invariant test catalog

Every invariant above lands as a behavior test in the new package before integration. The recovery suite must cover, at minimum: supersede coalescing (automatic joins, explicit replaces), dial-gated-on-endpoint-ready, retry-stops-on-ready, level-triggered rebuild from every terminal state, cooldown persistence across teardown, 401-single-recovery, suspension-spanning-probe abandonment, generation-fence rejection of stale continuations, and Tailscale-only strict enforcement with socket-level teardown proof.
