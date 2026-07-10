# Iroh app transport architecture

Status: accepted for implementation, July 2026.

This document defines the replacement transport for cmux mobile. It supersedes earlier experimental Iroh designs. Iroh is the default app transport. Tailscale, LAN, and user-configured private networks remain optional ways to reach the same Iroh endpoint.

## Boundaries

cmux uses Iroh for application sessions. It does not implement a general IP VPN or expose arbitrary private-network resources. A future private-resource feature must use named, allowlisted exports through an authenticated Mac.

An Iroh EndpointID is peer identity. IP addresses, relay URLs, Bonjour records, Tailscale addresses, and VPN addresses are reachability hints only. No hint can authorize a peer, select an account, or alter a grant.

The legacy Tailscale TCP transport remains during migration for released clients. New functionality uses Iroh. Tailscale and other private networks eventually supply fallback Iroh paths instead of separate application protocols.

## Connection plan

Each process owns one Iroh endpoint. A peer route contains one canonical 64-character lowercase hexadecimal EndpointID and separately attributed path hints.

Production endpoints start from Iroh's `Minimal` preset and add the cmux relay fleet explicitly. They do not use the default n0 preset, public n0 DNS address lookup, or public n0 relays. The authenticated cmux device registry is the application-specific address lookup: an endpoint publishes its signed current `watch_addr` value, and same-account peers resolve a known EndpointID through that registry. This distinction is required because an EndpointID authenticates a peer but does not say where that peer is reachable.

cmux-supplied addresses have two explicit phases:

1. Try Iroh-native discovery, globally routable direct addresses, and the managed relay fleet.
2. After phase one fails, try current LAN, Tailscale, and custom-private-network hints whose source-bound profile is active.

Private hints never enter the first cmux-supplied `EndpointAddr`. Iroh treats supplied IP paths as equivalent candidates, so array order is not a fallback boundary.

This phase split is not an IP-privacy boundary. During relay-assisted NAT traversal, Iroh itself exchanges public addresses, ports, and local addresses between the two TLS-authenticated EndpointIDs, then may migrate the connection to any working direct path. Iroh 1.0 does not expose relay-only mode or a per-connect candidate filter. A same-account peer may therefore learn LAN, Tailscale, or other interface addresses during phase one even when cmux supplied only a relay URL. cmux documents this behavior and does not claim peer-IP concealment. If managed deployments require relay-only traffic, rollout waits for upstream relay-only support or an opt-in fork hook whose default leaves upstream path selection unchanged.

For normal online sessions, this in-band candidate exchange is the generic private-network integration: Iroh can discover a working LAN or VPN interface without cmux publishing private addresses through the broker or identifying a VPN vendor. Explicit provider-qualified private hints are reserved for relayless/offline recovery and environments where Iroh did not discover the path itself. Tailscale raw TCP remains a released-client fallback, not the model for every private network.

Path migration may move an established connection between relay and direct reachability without reopening application streams. cmux treats this as one connection and does not assume Iroh stripes bandwidth across paths.

[Upstream issue 4247](https://github.com/n0-computer/iroh/issues/4247) documents asymmetric and relay-biased path selection even when a faster local direct path exists. cmux measures the selected route class and private-path outcomes. Tests distinguish cmux-supplied hints from Iroh-discovered candidates instead of asserting that private addresses cannot affect the first connection, which Iroh 1.0 cannot guarantee.

[Upstream issue 4390](https://github.com/n0-computer/iroh/issues/4390) can multiply `pending_open_paths` without bound when at least two connections encounter persistent path-open failures, including failures from unreachable overlay hints. The pinned cmux fork carries deduplication and a hard cap, with deterministic tests that exhaust path IDs across multiple connections. Releasing an FFI artifact that pins that exact audited core revision remains a rollout gate.

Private hints expire within one hour. They use literal IP and port values, never hostnames, URLs, CIDRs, or userinfo. A hint is usable only when its provider and profile match the locally active provider profile. This prevents overlapping private address spaces from substituting one another.

The active-profile snapshot carries a network-path generation. A slow public attempt must revalidate that generation immediately before using an explicit private fallback; a VPN or interface change cancels the stale fallback instead of dialing an address from the prior network.

The wire profile identifier is a provider-qualified, 32-byte account-scoped HMAC digest encoded as canonical lowercase hexadecimal. Human network names remain local UI metadata and never enter discovery, logs, or grants.

An RFC1918, ULA, or CGNAT address does not prove which private network is active. A Tailscale profile may be activated only by Tailscale-specific interface ranges plus a matching MagicDNS resolution when those signals are available. A custom profile declares an expected DNS probe or address range and may require explicit user activation. If iOS cannot identify another vendor's VPN reliably, cmux prompts before the fallback attempt instead of guessing. Iroh still authenticates the EndpointID after reachability succeeds.

iOS normally permits one active packet-tunnel VPN. cmux never starts a competing tunnel, and the connection UI must explain when selecting one private-network profile makes another unavailable.

The Mac exposes a stable configurable UDP listen port, or a small documented port range, for Iroh direct paths. This lets Tailscale ACLs and corporate firewalls allowlist cmux. An ephemeral-only UDP listener is insufficient for managed private-network deployments. Relay fallback remains available where UDP is blocked.

Apple endpoints disable Iroh's automatic UPnP, PCP, and NAT-PMP port mapping. Its SSDP replies can trigger the macOS firewall dialog, and on iOS the multicast probe can request Local Network access before the user invokes LAN discovery. Hole punching and managed relays remain enabled. A future explicit port-mapping preference must explain the prompt and cannot silently restore the upstream default.

Bonjour supplies local reachability, not trust. A known EndpointID authenticates a discovered peer. First-time offline pairing requires a QR or one-time local proof. Serialized IPv6 link-local addresses are rejected because an interface scope is local to the receiving device. An IPv6-link-local-only LAN therefore requires relay reachability or a future scope-aware Iroh API; cmux does not strip a scope and risk dialing the wrong interface.

Bonjour must not advertise a stable EndpointID, account identifier, email, device name, build tag, or private-network profile. Same-account devices use a rotating opaque rendezvous alias and opaque SRV hostname derived from a backend-issued local-discovery secret and a bounded time epoch. Revocation rotates that secret. A first-time offline QR carries a separate one-use rendezvous value. The TXT record contains only its version, epoch, and interface-local numeric Iroh addresses. The phone obtains the EndpointID from its authenticated registry or QR proof before dialing, verifies the alias against that exact binding, rejects off-link addresses, then still requires Iroh TLS and a signed pair grant.

Offline LAN discovery is opt-in. The iOS target must declare its cmux Bonjour service in `NSBonjourServices`, retain a localized local-network usage reason, and browse only when reconnecting a known Mac. A normal Iroh connection may also trigger Apple's Local Network prompt when NAT traversal tests an authenticated peer's LAN candidate. Denial disables Bonjour and direct LAN paths but must leave managed-relay connectivity working.

## Authorization

Iroh's TLS handshake proves possession of the EndpointID key. A cmux pair grant proves that the two exact endpoints belong to the same Stack account and may speak `cmux/mobile/1`.

The backend issues an Ed25519-signed grant bound to both device IDs, both EndpointIDs, both endpoint generations, the ALPN, scope, issuance time, expiry, and a unique grant ID. After the QUIC handshake, the Mac verifies the signature, time window, exact local acceptor tuple, and TLS initiator EndpointID before making a broker request. An arbitrary unauthenticated peer therefore cannot use admission attempts to induce authenticated HTTP traffic.

For a locally valid grant, the Mac checks authenticated discovery for exactly one matching initiator row and one matching acceptor row. The acceptor must remain pairing-enabled, the route contract must match, and the broker relay fleet must equal the complete app allowlist. Successful snapshots are shared across concurrent admissions for at most 30 seconds. Authentication, HTTP, decoding, contract, fleet, missing-binding, and ambiguous-binding failures deny admission. Only the broker's exact connectivity error permits the locally valid signed grant to continue offline.

Every admitted session retains its signed-authority expiry and revalidates broker state at the same maximum 30-second interval, including while application streams are idle. The first revalidation deadline is measured from the snapshot fetch time, so cached admission and timer scheduling cannot extend the bound to 60 seconds. A confirmed revoke or terminal broker-policy error closes that peer connection and its child streams without recreating the process's Iroh endpoint. Connectivity failure preserves the existing connection and retries. Once a valid online snapshot proves either signed binding absent, ambiguous, or disabled, that denial remains sticky for the runtime and later connectivity failure cannot restore offline access.

Pair grants last seven days and refresh daily or when less than 72 hours remain. An admitted session closes at grant expiry even if its streams remain idle. This permits offline reconnect while bounding the window in which a continuously disconnected revoked phone can reuse a cached grant. The Mac's local pairing-disabled and device-revocation state takes precedence immediately.

The iOS offline cache is device-only and scoped to the exact Stack account, app instance, local EndpointID and generation, relay fleet, target binding, rendezvous generation, verification key set, and signed grant expiry. It is consulted only for broker connectivity failures. Authentication, TLS, HTTP, decoding, contract, relay-fleet, ambiguity, and substitution failures fail closed. Sign-out, account switch, reinstall, and identity rotation delete it. A device and Mac that remain disconnected from the broker cannot learn a new remote revocation until the signed grant expires, so seven days is the deliberate residual disconnected-revocation window.

The five-minute first-pair invitation remains one-use and requires two valid one-day same-account endpoint attestations. The Mac verifies the invitation proof, live TLS initiator, both attestation signatures, their same-account subject, and both expiries before any discovery request, then consumes the invitation. If the broker is reachable, the same exact binding, contract, complete-fleet, and pairing-enabled checks apply. Only exact connectivity permits admission offline. The resulting session expires at the earlier attestation expiry and follows the same 30-second revalidation monitor, so its residual continuously disconnected revoke window is at most one day and it cannot become an indefinitely reusable unsigned credential.

Stack bearer and refresh tokens never cross an Iroh connection. Route hints never appear in grant claims. The discovery registry is scoped to the authenticated personal account, not the currently selected Stack team.

The endpoint hook rejects peers without an active or locally pending grant before application streams are accepted. The first grant frame, concurrent handshakes, streams per connection, frame sizes, and unauthenticated processing time all have fixed limits. A peer is admitted only after the TLS EndpointID matches both the connection and the signed grant.

Registration requires a one-use backend challenge and a signature from the endpoint key. Endpoint rotation requires proof from the old and new keys. Lost-key recovery creates a new endpoint and requires reapproval.

## Identity lifecycle

The endpoint secret is a 32-byte Ed25519 key stored with `AfterFirstUnlockThisDeviceOnly` data protection. It is not synchronized or backed up. Account switching rotates the key. Because Keychain items can survive app deletion, an app-container installation marker detects reinstall and rotates any surviving key before registration.

Identity generation and runtime generation are separate values. Identity generation changes only when the key or account binding changes and is included in registration and grants. Runtime generation changes whenever an endpoint instance is recreated and remains local, where it rejects stale async results. Foreground recreation must not invalidate a cached offline grant.

iOS may suspend networking in the background, but cmux does not proactively close a healthy endpoint or its established QUIC streams on every background transition. It stops nonessential discovery and refresh work while preserving the live endpoint for as long as the OS permits. Foreground activation first checks the existing generation; if the OS terminated or invalidated it, cmux recreates the endpoint from the same secret, preserves EndpointID, then redials and resumes streams from application cursors. Every async result is generation-checked so an old endpoint cannot mutate new state.

[Upstream issue 4289](https://github.com/n0-computer/iroh/issues/4289) shows that a failed UDP rebind after iOS resume can silently terminate the EndpointDriver without surfacing an API error. cmux requires an endpoint-health watchdog. A terminal health failure recreates the endpoint from the same key and identity generation while advancing the runtime generation, then resumes application streams from their cursors.

The fork must expose cancellation for an in-progress connect. Closing a QUIC connection unblocks established stream reads, but it does not reliably cancel the current FFI handshake bridge.

## Relay fleet

Production endpoints use only these managed relays:

- `https://euc1-1.relay.lawrence.cmux.iroh.link/`
- `https://use1-1.relay.lawrence.cmux.iroh.link/`
- `https://usw1-1.relay.lawrence.cmux.iroh.link/`
- `https://aps1-1.relay.lawrence.cmux.iroh.link/`

The four URLs form the local endpoint's allowed relay fleet. They must not all be synthesized as addresses for every remote endpoint. A remote `EndpointAddr` contains only the remote endpoint's currently advertised home relay or relays, validated against the fleet allowlist. Iroh currently expects zero or one home relay in normal operation. Fleet configuration and remote reachability are separate wire fields.

The Iroh Services project secret stays in a backend-only secret store. Apps receive an endpoint-bound RCAN containing only `relay:use`. Relay capabilities last 24 hours and refresh around 12 hours with jitter. The RCAN minter is a separately deployed Rust service and project, so the TypeScript trust broker cannot read `IROH_SERVICES_API_SECRET`; only a shared HMAC crosses that boundary. The API key pasted during planning must be rotated before deployment.

Relay replacement must be behavior-tested before rollout. Iroh 1.0 caches the authentication token in an active relay actor, so updating a relay map entry alone may not refresh a live actor. The implementation must use an explicit fork API or make-before-break rotation and prove that EndpointID and active application streams survive refresh.

[Upstream issue 4319](https://github.com/n0-computer/iroh/issues/4319) reports roughly 30 seconds of lost reachability after a custom home relay fails even when another relay is configured. Relay failover and rolling restarts require a soak and telemetry gate that measures inbound-reachability gaps, stream survival, and recovery latency. cmux does not claim relay high availability until those bounds pass.

No n0 public DNS discovery or development relay enters the production preset. Relay URL syntax validation is separate from the runtime allowlist above.

Iroh 1.0 relay-over-WebSocket does not honor a system HTTP proxy. A network that permits outbound traffic only through an explicit HTTP CONNECT proxy may therefore make every Iroh route unavailable even though ordinary HTTPS works. cmux retains the released-client Tailscale/private-network transport for this case and reports the Iroh failure. Proxy-only Iroh support remains gated on an upstream transport hook or a reviewed fork implementation.

End-to-end encryption does not hide connection metadata. A relay can observe source and destination IP addresses, endpoint identifiers, timing, and relayed byte counts. A direct peer learns the other peer's reachable IP address. cmux must disclose this in privacy documentation and must not enable Iroh Services network-diagnostics capabilities without explicit user consent. Relay-only peer-IP privacy is not a v1 launch claim.

The app derives path quality from local Iroh connection statistics. Product telemetry may report aggregate route class, relay region, latency bucket, reconnect result, and byte bucket, but never IP addresses, private hints, full EndpointIDs, grants, or tokens. The Iroh Services project API secret is not embedded to obtain diagnostics or dashboard metrics.

## Streams and capabilities

The initial ALPN is `cmux/mobile/1`. One QUIC connection multiplexes:

- a control stream for grants, requests, and lifecycle messages;
- a server-event stream with sequence cursors;
- one stream per terminal;
- low-priority artifact streams with independent cancellation and backpressure.

Datagrams carry only disposable hints. Mutating requests never use 0-RTT.

The official Swift FFI exposes raw QUIC connections, bidirectional and unidirectional streams, datagrams, relays, and connection statistics. It does not expose every Iroh protocol crate. cmux maintains a minimal fork for Apple platform support, cancellation, and required bindings. Blobs, documents, and gossip are added incrementally with protocol-level tests. Large resumable verified artifacts are a likely blobs use case; latency-sensitive previews should first use low-priority streams on the existing connection. Iroh 1.0 has an open single-stream blob-throughput regression on LAN, so artifact adoption requires chunking and measured end-to-end throughput rather than assuming the typed protocol is faster. Gossip and docs each require their own memory, persistence, compaction, and mobile-energy soak before product use.

## Disclosure and persistence

Private and local path hints may travel only through an authenticated same-account channel. They are excluded from identity-only pairing QR payloads, public host status, logs, support bundles, public discovery, and cloud backup. Public host status returns zero attach routes. Persisted routes prune expired hints. Logs use classifications or keyed hashes, never full EndpointIDs, relay tokens, grants, or private addresses.

Pairing QR encoding requires an explicit disclosure mode. `irohIdentityOnly` keeps only the Iroh EndpointID and removes every path hint, host/port route, token, and URL route. It is the production default whenever an Iroh route exists. The Mac can separately generate a user-invoked `legacyPrivateNetworkCompatibility` QR for released clients that still require Tailscale or another private-network address. If Iroh is unavailable, the compatibility QR remains the only supported path; loopback alone is never considered pairable.

Application-layer reachability can bypass DNS filters or network-layer allowlists. Managed deployments need an MDM/configuration policy that can disable Iroh, restrict it to approved relay URLs, or require the legacy private-network path. cmux does not disguise relay traffic or create an alternate way around an administrator's access policy.

Connection UI reports the app transport and the observed outer provider separately, for example `Iroh via Tailscale`. A Tailscale path may itself use DERP, so cmux must not label that state as a direct physical path.

Public direct hints must be globally routable. Direct values reject loopback, unspecified, multicast, broadcast, metadata endpoints, ambiguous numeric forms, and IPv6 link-local wire values. Managed relay URLs require root HTTPS URLs and a runtime allowlist match.

## Release gates

Before defaulting to Iroh, verification must cover:

- arm64 and Intel macOS, including macOS 14.0;
- arm64 iOS devices and arm64/x86_64 Simulators;
- direct, NAT-traversed, relay-only, LAN, Tailscale, and custom-profile paths;
- TCP-only firewalls, blocked UDP, captive portals, constrained paths, and expensive cellular paths;
- explicit HTTP-proxy-only networks, with a clear legacy/private-network fallback until Iroh relay WebSockets support proxy-controlled connection establishment;
- relay token denial, expiry, refresh, and long-lived stream preservation;
- background and foreground endpoint recreation with stable EndpointID;
- a deterministic failed-rebind/network-resume test that proves the health watchdog detects terminal driver failure and recreates the endpoint from the same key and identity generation with a new runtime generation;
- measured direct, relay, and private-fallback path selection, including asymmetric traffic, classification of cmux-supplied versus Iroh-discovered candidates, and stale-profile cancellation before explicit fallback;
- long-lived multi-interface and VM-bridge connections, checking periodic path churn, battery use, congestion resets, and accidental relay selection;
- the pinned Iroh core's `pending_open_paths` deduplication and hard cap, plus an adversarial multi-connection test with failing overlay hints that asserts bounded queue and memory growth;
- custom-home-relay failure and rolling-restart soaks with bounded reachability and stream-recovery telemetry;
- regional relay instance loss and capacity exhaustion, because one relay per region is currently one regional failure domain even though other regions can recover reachability;
- a long-running Router soak with tracing enabled and idle adversarial connections, guarding against the span accumulation in [upstream issue 3963](https://github.com/n0-computer/iroh/issues/3963);
- same-account grant success plus cross-account, swapped-peer, revoked, expired, and replay denial;
- coalesced online admission refresh, sticky learned revocation, idle-session closure within 30 seconds of an observable revoke, connectivity preservation, and closure at grant expiry without endpoint recreation;
- offline cached-grant reconnect and explicit first-time offline pairing;
- stream fairness, cancellation, reconnect cursors, and artifact backpressure;
- mobile energy use, relay byte use, and Low Data Mode behavior;
- a final security and privacy pass over wire data, persistence, logs, and backend abuse limits.

GitHub's hosted `macos-14-large` runner provides the required Intel Sonoma lane today, but GitHub began deprecating macOS 14 images on July 6, 2026 and plans to remove them on November 2, 2026. cmux must move this release gate to an Intel lab runner before that date rather than silently dropping macOS 14 coverage.

Current regional capacity is provisional until fresh PostHog geography data is available. The stale sample suggests the existing US, EU, and AP coverage is reasonable, but Tokyo or Seoul may merit an additional relay after a current query.
