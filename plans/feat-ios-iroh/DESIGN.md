# iroh as the default cmux iOS-to-Mac transport

Status: spike green, design committed, implementation planned as stacked PRs (see "Delivery plan"). Decision (Lawrence, 2026-06-09): iroh is the DEFAULT transport; Tailscale becomes opt-in. Onboarding "just works" with sign-in plus dial-by-EndpointId; no VPN install, no network setup.

## What this is and is not

This is a substrate swap, not a protocol rewrite. The existing mobile-host protocol (length-prefixed JSON frames, `MobileSyncFrameCodec`, the `mobileHostHandleRPC` allowlist, render-grid data plane, per-RPC Stack same-account auth) is unchanged byte for byte. Today those frames ride one TCP connection over Tailscale; after this they ride one iroh QUIC bidirectional stream, dialed by EndpointId. Everything above the byte stream stays put.

The codebase already reserved the seams for this:

- `CmxAttachTransportKind.iroh` exists and validates against `.peer` endpoints (`Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxTransport.swift`).
- `CmxAttachEndpoint.peer(id:relayHint:directAddrs:relayURL:)` already carries exactly what an iroh dial needs.
- `MobileShellRouteAuthPolicy` already classifies `(.iroh, .peer)` as an encrypted route that may carry Stack tokens (`Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel/MobileShellRouteAuthPolicy.swift`).
- The phone builds transports through `CmxRouteTransportFactory` keyed by route kind; adding a kind is one registration in `ios/cmux/cmuxApp.swift`.
- The device registry (merged, https://github.com/manaflow-ai/cmux/pull/5626) stores `CmxAttachRoute` lists as opaque jsonb, so an `iroh` route needs zero schema change, and the phone's `DeviceRegistryService` already skips unknown route kinds on old builds (forward compatible).
- Settings diagnostics already have a localized "Iroh" route label (`Sources/HostSettingsActions.swift`).

## Spike results (gating risk: retired)

Spike code: `experiments/iroh-swift-ffi-spike/` (full notes in its README).

- Bindings: the official uniffi bindings (https://github.com/n0-computer/iroh-ffi) are archived, last release v0.35.0 tracks pre-1.0 iroh. n0's guidance is a custom wrapper. We use a ~400-line Rust staticlib over iroh `1.0.0-rc.1` exposing a minimal blocking C API (bind, id, route JSON, online, accept, connect, recv, send, close), consumed from Swift via a bridging header.
- Proof: an arm64 iOS-simulator process (iPhone 17, iOS 26.4) dialed a macOS process by EndpointId alone (no address hints, n0 discovery plus relays) and round-tripped bytes; connect took 0.50 to 1.03s. Both sides exited clean.
- Size: staticlib 15 MB; real post-link, dead-stripped app delta is about +7.7 MB per architecture slice (measured harness vs trivial Swift CLI baseline).
- Frameworks needed: macOS `SystemConfiguration CoreWLAN Security`; iOS `SystemConfiguration Security Network`.

## Architecture

### Mac (host) side

`MobileHostService` gains an iroh listener lane next to the existing `NWListener`:

1. On host start, bind one long-lived iroh endpoint (ALPN `dev.cmux.mobile.terminal/0`) with a persisted secret key (Keychain, below). Bind is lazy with the same enable gates as the TCP listener.
2. Accept loop: each accepted connection plus first bi-stream becomes a `MobileHostConnection`. Today that actor talks to `NWConnection` directly in exactly three places (`receiveNext`, send, state handler). Introduce a small `MobileHostByteConnection` protocol (receive/send/close, the server-side mirror of `CmxByteTransport`) with an `NWConnection` adapter and an iroh adapter. All connection-lifecycle logic (frame codec, first-frame and idle timeouts, subscriptions, RPC dispatch, connection registry, max-connection cap) is already transport-agnostic and is reused unchanged.
3. Route publication: `MobileRouteResolver` adds one `iroh` route built from the endpoint (EndpointId, current relay URL, direct addrs) at a priority that beats Tailscale (lower number wins in `preferredRoute`). The route flows everywhere routes already flow: attach tickets, QR payloads, and `DeviceRegistryClient` POSTs to `/api/devices`.
4. The loopback-reject rule stays on the TCP lane. The iroh lane has no loopback concept; its equivalent floor is that QUIC handshake requires the dialer to know the EndpointId, and the Stack same-account check still gates every RPC.

### iPhone (client) side

One new transport, one registration:

1. `CmxIrohByteTransport: CmxByteTransport` (actor) wrapping the C FFI: `connect()` binds the phone endpoint (if needed) and dials the route's peer endpoint with relay/addr hints; `receive()`/`send()` map to stream reads/writes off the main thread; `close()` finishes the stream and closes. The blocking FFI calls run inside the actor like `CmxNetworkByteTransport` runs its continuation plumbing today; the shared tokio runtime in the staticlib does the async work.
2. Register `.iroh` in `cmuxApp.swift`'s `supportedKinds`. `CmxAttachTicket.preferredRoute(supportedKinds:)` then automatically prefers the iroh route on new builds while old builds keep picking Tailscale.
3. Connection failure classification: map iroh connect errors into the existing `CmxConnectFailureKind` so the UI keeps giving actionable messages ("Mac offline" vs "relay unreachable").

### Onboarding flow (the point of all this)

1. User signs into the iOS app (Stack).
2. `DeviceRegistryService` lists the account's Macs; each instance's routes jsonb now includes the iroh route with the Mac's EndpointId.
3. Phone dials by EndpointId. n0 discovery finds the Mac through its home relay; QUIC holepunches to a direct path when possible, relay carries traffic otherwise. No VPN, no LAN requirement, no QR.
4. Every RPC still carries the Stack access token; the Mac verifies same-account server-side. The registry is rendezvous, never authority (unchanged from https://github.com/manaflow-ai/cmux/pull/5626).

QR pairing remains exactly what it is today: first-trust UX and the fallback when the registry is unreachable. The QR payload's routes list simply includes the iroh route, so a QR pair also yields an EndpointId the phone can keep dialing from anywhere.

## Security and E2E story

iroh QUIC connections are end-to-end encrypted with TLS 1.3 using raw public keys: the EndpointId IS the peer's public key, and the handshake fails unless the dialed peer holds the matching secret key. Relays carry ciphertext only and cannot MITM a dial-by-EndpointId. This means the planned Noise IK layer (from the earlier pluggable-transports design, which assumed untrusted relays under plain TCP) is not needed for the iroh lane: the channel is already authenticated to the key we dialed.

What that reduces the trust problem to: distributing the authentic Mac EndpointId. The threat that matters is credential exfiltration, not host impersonation alone: the phone sends its Stack access token inside the protocol on every RPC, so a substituted route (compromised registry, authz bug, malicious route write) would receive a live bearer token from a phone that dials it. That exposure exists today with substituted host:port routes; iroh is the lane that can actually close it, because the channel is cryptographically bound to the EndpointId being dialed.

So EndpointId pinning ships in the first iroh lane (PR 3/4), not later:

- The phone pins the Mac's EndpointId in `MobilePairedMacStore` at first trust. QR pairing pins from physical proximity. Registry-only auto-pair pins on first attach (TOFU), which is no weaker than today's registry-trusted host:port baseline and strictly stronger afterwards.
- After pinning, the phone sends Stack tokens over iroh only to a connection whose dialed EndpointId matches the pinned one for that device row. A registry that later substitutes a different EndpointId cannot get a token: the dial either fails the QUIC handshake (wrong key) or fails the pin check before any frame is sent.
- A changed EndpointId for a known device (legitimate after a Mac Keychain reset) is surfaced to the user for explicit re-trust, never silently accepted.

Key custody: the iroh secret key is a 32-byte Ed25519 key. Mac and phone each generate once and store in Keychain as `kSecClassGenericPassword` with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no iCloud sync (a synced key would make two devices claim one EndpointId). The FFI gains `bind` taking an optional caller-provided key plus a key-generation call, so key material lives in Swift/Keychain and is passed in, not minted and held inside Rust.

A stable phone-side key also gives every phone a stable EndpointId, which is the natural per-device identity the device-revoke design (cmuxterm-hq `plans/feat-ios-device-revoke/DESIGN.md`) was missing; the Mac can pin known client EndpointIds later. Not in scope for P1, but the keys are persisted from day one so the option exists.

## Relay strategy

Now: n0's default relay fleet via `presets::N0` (free public infrastructure run by n0; relays are dumb encrypted-byte forwarders). Note from the spike: iroh 1.0.0-rc endpoints currently land on n0's canary relays (`relay.n0.iroh-canary.iroh.link`); before shipping, pin the stable relay map and re-verify at iroh 1.0 GA.

Later: self-host `iroh-relay` (open source, stateless, cheap) under cmux.dev and set it as the relay map, keeping n0 as fallback. The `relay_url` field in routes means each Mac advertises whichever relay it actually homes on, so mixed fleets work during any migration. Self-hosting removes the third-party availability dependency and is the right place to add usage metrics.

## iOS background and battery behavior

An idle iroh endpoint maintains a relay connection and periodic keepalives. Policy: the phone's endpoint lifecycle is tied to the attach session and scene phase, exactly like today's TCP connections. Bind on first connect, close the endpoint when the app backgrounds (the existing scenePhase handling in `cmuxApp.swift` is the hook) and rebind on foreground attach. No background networking entitlement, no persistent background socket, so no new battery cost class: radio use happens only while the user is actually attached. Reconnect-on-foreground is fast (sub-second connect in the spike, plus the session/RPC layer already handles transport drops and re-dials).

The Mac side keeps its endpoint bound whenever the mobile host is enabled, same as the TCP listener today. Mac battery impact is a relay keepalive, negligible against a running cmux.

## Tailscale and LAN: opt-in fallback

New Settings toggle on the Mac (Mobile section): "Also publish Tailscale/LAN routes" (exact copy TBD, localized en+ja like every string in this feature). Semantics:

- ON: `MobileRouteResolver` publishes tailscale routes (current behavior) in addition to iroh, at lower preference.
- OFF (eventual default): only iroh (plus debug loopback in DEBUG).

Rollout compatibility: during the transition the toggle defaults ON so existing paired phones on old builds (which only support `.tailscale`) keep connecting; `preferredRoute` picks iroh on new phones automatically because of priority ordering. Flipping the default to OFF is a later, separate change once the fleet has the iroh-capable build. Direct LAN connectivity does not actually need Tailscale at all under iroh: direct addrs in the iroh route make same-LAN dials holepunch-free, so the toggle is genuinely only for people who want the tailnet path.

## Production transport configuration (three modes)

Production requires both lanes to ship and a user-visible choice of which one carries their phone. The two development booleans (`mobile.iOSPairingHost.enabled`, `mobile.iOSIrohHost.enabled`) collapse into one transport-mode picker plus a relay-URL field, all in the Mobile settings section.

`mobile.iOSTransportMode` (enum, default `cmuxRelay`):

- **cmuxRelay** (cmux-hosted iroh, recommended): iroh endpoint binds against the cmux/n0 relay map. Works off-LAN with zero setup. This is the dogfood lane.
- **ownRelay**: iroh endpoint binds against `mobile.iOSIrohRelayURL` (a validated `https://` relay the user runs via open-source `iroh-relay`). The bound endpoint homes on that relay, so `route_json` advertises it and the phone dials through it with no phone-side config (`CmxAttachEndpoint.peer` already carries `relayURL`).
- **tailscale**: iroh lane stays off; the TCP/LAN listener (today's `iOSPairingHost` behavior) publishes tailscale/LAN routes only. For users who already run a tailnet and want no relay dependency.

`mobile.iOSIrohRelayURL` (string, default empty): only meaningful in `ownRelay`; the UI shows the field only for that mode and validates a non-empty `https://` URL before binding.

Mechanism / code impact:

- **FFI**: `cmux_iroh_endpoint_bind` grows an optional relay-URL argument (nil → default cmux/n0 map; set → custom relay map). `cmux_iroh_endpoint_route_json` must emit whichever relay the endpoint actually homed on so the published route is dialable. The dial side (`cmux_iroh_endpoint_connect`) already takes `relay_url`, so the phone is unchanged.
- **CmxIrohByteListener**: gains a relay config (default vs custom URL) passed to bind.
- **MobileHostService**: reads `iOSTransportMode`, binds the iroh listener with the resolved relay, and gates each lane on the mode. This also **decouples the iroh accept lane from the pairing-host (`isListeningEnabled`) gate** it currently sits behind, so `cmuxRelay`/`ownRelay` can run without the tailscale listener.
- **Migration**: old booleans map forward — iroh-on → `cmuxRelay`; iroh-off + pairing-on → `tailscale`; both-off → a new `off` case (mobile host disabled).
- **Localization**: picker label, three option labels, relay-URL field label + validation error, all en+ja. **Docs**: configuration docs + `cmux.json` schema (this is a setting, not a shortcut).

## Packaging (no vendored binaries)

The spike's Rust crate graduates to `native/cmux-iroh/` in-repo (source only, Cargo.lock committed). A `scripts/ensure-cmux-iroh.sh` builds `CmuxIrohFFI.xcframework` (macOS arm64+x86_64, iOS device arm64, iOS sim arm64) into a gitignored path, mirroring the GhosttyKit pattern (`scripts/ensure-ghosttykit.sh`, gitignored `GhosttyKit.xcframework`). CI and fleet builders gain a pinned Rust toolchain step next to the existing pinned Zig step (`scripts/install-zig-ci.sh` precedent). The xcframework links into the Mac app and the iOS app; binary cost is about +7.7 MB per slice (measured in the spike), which is acceptable against the existing GhosttyKit payload.

This toolchain addition (Rust on every CI runner and fleet builder) is the main reason P1 is its own PR rather than bundled with the spike: it touches build infrastructure shared by every job and deserves isolated review and a canary CI run.

## Reconciliation with the hive design

cmuxterm-hq `plans/feat-hive/DESIGN.md` assumed "Tailscale is the substrate the user sets up; cmux assumes it and verifies it" with iroh as a P3 seam. This decision inverts that for phone-to-host: iroh is the default substrate and Tailscale is the opt-in. What carries over unchanged from hive, because the hive node contract was deliberately transport-pluggable:

- The hive node contract (frame codec, Stack auth, capabilities, render-grid, registry) does not name a transport; an iroh route is just another `CmxAttachRoute` kind in the registry's opaque routes jsonb.
- Linux hive nodes get iroh almost free: the host body is the Go `cmuxd-remote`, which can cgo the same C FFI staticlib (it is the same Rust crate, built for linux targets), or n0's Go path if that is cleaner at implementation time. The "headless box needs its own Stack credential" problem from hive is unchanged and orthogonal.
- Hive's "verify, don't manage" Tailscale UX (the phone-side `TailscaleStatus` detector, https://github.com/manaflow-ai/cmux/pull/5722) becomes the opt-in lane's diagnostics instead of the default lane's.
- Hive's P1 "tailnet-only, WireGuard is the encryption" security story is superseded on the default lane by iroh's QUIC raw-public-key TLS, which is stronger in one respect: it is end to end per-peer rather than per-network.

The hive doc should be updated to say: default connectivity = registry routes dialed iroh-first; Tailscale/LAN = opt-in fallback routes. Nothing else in it changes.

## Delivery plan (stacked PRs)

P1 is not bundled here because it carries a build-toolchain change for all CI and fleet builders; the seam work itself is mechanical. Stack, each independently revertable:

1. **This PR**: spike (`experiments/iroh-swift-ffi-spike/`) plus this design doc. No app/runtime changes, no reload needed.
2. **PR 2, packaging**: `native/cmux-iroh/` crate (FFI grown to caller-provided keys and error-kind codes), `scripts/ensure-cmux-iroh.sh`, Rust toolchain in CI, xcframework linked into both apps but referenced by nothing. Proves the build matrix everywhere without behavior change.
3. **PR 3, phone dial lane**: `CmxIrohByteTransport` in `Packages/iOS/CmuxMobileTransport` plus registration, behind a feature flag (DEBUG default ON, release default OFF). Includes the EndpointId pin gate from the security section: pin at first trust in `MobilePairedMacStore`, refuse to send Stack tokens to a non-matching EndpointId, explicit re-trust UX on change. Unit tests with the existing transport test doubles; one loopback-style integration test dialing a local iroh listener.
4. **PR 4, Mac host lane**: `MobileHostByteConnection` seam extraction in `MobileHostService` (pure refactor commit first, NWConnection adapter only, zero behavior change), then the iroh accept loop, Keychain key custody, route publication in `MobileRouteResolver`, registry propagation. Same feature flag.
5. **PR 5, three-mode transport config**: the two dev booleans become the `mobile.iOSTransportMode` picker (`cmuxRelay` default / `ownRelay` / `tailscale`) plus the `mobile.iOSIrohRelayURL` field, per the "Production transport configuration" section above. Includes the FFI custom-relay-bind extension, the iroh-lane decoupling from the pairing-host gate, migration from the old booleans, strings en+ja, and config/schema docs. Gated behind the PR-4 dogfood proving the `cmuxRelay` substrate attaches e2e.

Dogfood gate between 4 and 5: phone on cellular (Tailscale off) attaches to the Mac by sign-in alone, terminal latency subjectively fine on both relay and holepunched paths, reconnect after backgrounding works.

## Open questions and risks

- **iroh 1.0 is rc**: API churn risk between rc.1 and GA is real but the surface we use (Endpoint, connect/accept, streams) is the stable core. Pin the version; re-verify the relay map at GA (canary-relay note above).
- **Discovery latency tail**: spike showed 0.5 to 1.0s connects on a warm network; cold relay discovery on bad networks needs measurement during PR 3/4 dogfood. The route's direct_addrs and relay_url hints cut discovery out of the hot path.
- **Staticlib size in the iOS app**: +7.7 MB/slice is fine for the dev/TestFlight app; recheck App Store thinning behavior at submission time.
- **Tokio runtime inside two apps**: one multi-thread runtime (2 workers) per process, sized in the FFI. No conflict with Swift concurrency observed in the spike; keep FFI calls off the main actor by construction (actor-isolated transport).
- **Same-account ceiling**: unchanged from today; team-shared Macs and per-device revoke remain future work (per-device identity now has a natural carrier in stable phone EndpointIds).
