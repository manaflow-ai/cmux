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

Dialing has two explicit phases:

1. Try Iroh-native discovery, globally routable direct addresses, and the managed relay fleet.
2. After phase one fails, try current LAN, Tailscale, and custom-private-network hints whose source-bound profile is active.

Private hints never enter the first Iroh address set. Iroh treats supplied IP paths as equivalent candidates, so array order is not a fallback boundary.

Path migration may move an established connection between relay and direct reachability without reopening application streams. cmux treats this as one connection and does not assume Iroh stripes bandwidth across paths.

Private hints expire within one hour. They use literal IP and port values, never hostnames, URLs, CIDRs, or userinfo. A hint is usable only when its provider and profile match the locally active provider profile. This prevents overlapping private address spaces from substituting one another.

The wire profile identifier is an opaque random value qualified by provider. Human network names remain local UI metadata and never enter discovery, logs, or grants.

An RFC1918, ULA, or CGNAT address does not prove which private network is active. A Tailscale profile may be activated only by Tailscale-specific interface ranges plus a matching MagicDNS resolution when those signals are available. A custom profile declares an expected DNS probe or address range and may require explicit user activation. If iOS cannot identify another vendor's VPN reliably, cmux prompts before the fallback attempt instead of guessing. Iroh still authenticates the EndpointID after reachability succeeds.

iOS normally permits one active packet-tunnel VPN. cmux never starts a competing tunnel, and the connection UI must explain when selecting one private-network profile makes another unavailable.

Bonjour supplies local reachability, not trust. A known EndpointID authenticates a discovered peer. First-time offline pairing requires a QR or one-time local proof. Serialized IPv6 link-local addresses are rejected because an interface scope is local to the receiving device.

Bonjour must not advertise a stable EndpointID, account identifier, email, device name, or private-network profile. Same-account devices use a rotating opaque rendezvous alias derived from a backend-issued local-discovery secret and a bounded time epoch. Revocation rotates that secret. A first-time offline QR carries a separate one-use rendezvous value. The service record supplies only the alias, protocol version, and port; the phone obtains the EndpointID from its authenticated registry or QR proof before dialing.

Offline LAN discovery is opt-in. The iOS target must declare its cmux Bonjour service in `NSBonjourServices`, retain a localized local-network usage reason, and request access only when the user enables or invokes LAN discovery.

## Authorization

Iroh's TLS handshake proves possession of the EndpointID key. A cmux pair grant proves that the two exact endpoints belong to the same Stack account and may speak `cmux/mobile/1`.

The backend issues an Ed25519-signed grant bound to both device IDs, both EndpointIDs, both endpoint generations, the ALPN, scope, issuance time, expiry, and a unique grant ID. The Mac verifies the grant locally after the QUIC handshake. Pairing-disabled and revoked devices fail locally even if a relay token remains valid.

Pair grants last seven days and refresh daily or when less than 72 hours remain. This permits offline reconnect while bounding the window in which a disconnected revoked phone can reuse a cached grant. The Mac's local pairing-disabled and device-revocation state takes precedence immediately.

Stack bearer and refresh tokens never cross an Iroh connection. Route hints never appear in grant claims. The discovery registry is scoped to the authenticated personal account, not the currently selected Stack team.

The endpoint hook rejects peers without an active or locally pending grant before application streams are accepted. The first grant frame, concurrent handshakes, streams per connection, frame sizes, and unauthenticated processing time all have fixed limits. A peer is admitted only after the TLS EndpointID matches both the connection and the signed grant.

Registration requires a one-use backend challenge and a signature from the endpoint key. Endpoint rotation requires proof from the old and new keys. Lost-key recovery creates a new endpoint and requires reapproval.

## Identity lifecycle

The endpoint secret is a 32-byte Ed25519 key stored with `AfterFirstUnlockThisDeviceOnly` data protection. It is not synchronized or backed up. Account switching rotates the key. Because Keychain items can survive app deletion, an app-container installation marker detects reinstall and rotates any surviving key before registration.

Identity generation and runtime generation are separate values. Identity generation changes only when the key or account binding changes and is included in registration and grants. Runtime generation changes whenever an endpoint instance is recreated and remains local, where it rejects stale async results. Foreground recreation must not invalidate a cached offline grant.

iOS cannot keep a normal endpoint alive indefinitely in the background. On background transition it closes the endpoint and cancels generation-owned work. On foreground it recreates the endpoint from the same secret, preserving EndpointID, then redials and resumes streams from application cursors. Every async result is generation-checked so an old endpoint cannot mutate new state.

The fork must expose cancellation for an in-progress connect. Closing a QUIC connection unblocks established stream reads, but it does not reliably cancel the current FFI handshake bridge.

## Relay fleet

Production endpoints use only these managed relays:

- `https://euc1-1.relay.lawrence.cmux.iroh.link/`
- `https://use1-1.relay.lawrence.cmux.iroh.link/`
- `https://usw1-1.relay.lawrence.cmux.iroh.link/`
- `https://aps1-1.relay.lawrence.cmux.iroh.link/`

The four URLs form the local endpoint's allowed relay fleet. They must not all be synthesized as addresses for every remote endpoint. A remote `EndpointAddr` contains only the remote endpoint's currently advertised home relay or relays, validated against the fleet allowlist. Iroh currently expects zero or one home relay in normal operation. Fleet configuration and remote reachability are separate wire fields.

The Iroh Services project secret stays in a backend-only secret store. Apps receive an endpoint-bound RCAN containing only `relay:use`. Relay capabilities last 24 hours and refresh around 12 hours with jitter.

Relay replacement must be behavior-tested before rollout. Iroh 1.0 caches the authentication token in an active relay actor, so updating a relay map entry alone may not refresh a live actor. The implementation must use an explicit fork API or make-before-break rotation and prove that EndpointID and active application streams survive refresh.

No n0 public DNS discovery or development relay enters the production preset. Relay URL syntax validation is separate from the runtime allowlist above.

End-to-end encryption does not hide connection metadata. A relay can observe source and destination IP addresses, endpoint identifiers, timing, and relayed byte counts. A direct peer learns the other peer's reachable IP address. cmux must disclose this in privacy documentation and must not enable Iroh Services network-diagnostics capabilities without explicit user consent. Relay-only peer-IP privacy is not a v1 launch claim.

The app derives path quality from local Iroh connection statistics. Product telemetry may report aggregate route class, relay region, latency bucket, reconnect result, and byte bucket, but never IP addresses, private hints, full EndpointIDs, grants, or tokens. The Iroh Services project API secret is not embedded to obtain diagnostics or dashboard metrics.

## Streams and capabilities

The initial ALPN is `cmux/mobile/1`. One QUIC connection multiplexes:

- a control stream for grants, requests, and lifecycle messages;
- a server-event stream with sequence cursors;
- one stream per terminal;
- low-priority artifact streams with independent cancellation and backpressure.

Datagrams carry only disposable hints. Mutating requests never use 0-RTT.

The official Swift FFI exposes raw QUIC connections, bidirectional and unidirectional streams, datagrams, relays, and connection statistics. It does not expose every Iroh protocol crate. cmux maintains a minimal fork for Apple platform support, cancellation, and required bindings. Blobs, documents, and gossip are added incrementally with protocol-level tests. Large resumable verified artifacts are a likely blobs use case; latency-sensitive previews should first use low-priority streams on the existing connection.

## Disclosure and persistence

Private and local path hints may travel only through an authenticated same-account channel. They are excluded from pairing QR payloads, public host status, logs, support bundles, public discovery, and cloud backup. Persisted routes prune expired hints. Logs use classifications or keyed hashes, never full EndpointIDs, relay tokens, grants, or private addresses.

Application-layer reachability can bypass DNS filters or network-layer allowlists. Managed deployments need an MDM/configuration policy that can disable Iroh, restrict it to approved relay URLs, or require the legacy private-network path. cmux does not disguise relay traffic or create an alternate way around an administrator's access policy.

Connection UI reports the app transport and the observed outer provider separately, for example `Iroh via Tailscale`. A Tailscale path may itself use DERP, so cmux must not label that state as a direct physical path.

Public direct hints must be globally routable. Direct values reject loopback, unspecified, multicast, broadcast, metadata endpoints, ambiguous numeric forms, and IPv6 link-local wire values. Managed relay URLs require root HTTPS URLs and a runtime allowlist match.

## Release gates

Before defaulting to Iroh, verification must cover:

- arm64 and Intel macOS, including macOS 14.0;
- arm64 iOS devices and arm64/x86_64 Simulators;
- direct, NAT-traversed, relay-only, LAN, Tailscale, and custom-profile paths;
- TCP-only firewalls, blocked UDP, captive portals, constrained paths, and expensive cellular paths;
- relay token denial, expiry, refresh, and long-lived stream preservation;
- background and foreground endpoint recreation with stable EndpointID;
- same-account grant success plus cross-account, swapped-peer, revoked, expired, and replay denial;
- offline cached-grant reconnect and explicit first-time offline pairing;
- stream fairness, cancellation, reconnect cursors, and artifact backpressure;
- mobile energy use, relay byte use, and Low Data Mode behavior;
- a final security and privacy pass over wire data, persistence, logs, and backend abuse limits.

GitHub's hosted `macos-14-large` runner provides the required Intel Sonoma lane today, but GitHub began deprecating macOS 14 images on July 6, 2026 and plans to remove them on November 2, 2026. cmux must move this release gate to an Intel lab runner before that date rather than silently dropping macOS 14 coverage.

Current regional capacity is provisional until fresh PostHog geography data is available. The stale sample suggests the existing US, EU, and AP coverage is reasonable, but Tokyo or Seoul may merit an additional relay after a current query.
