# Iroh app transport architecture

Status: accepted for implementation, July 2026.

This document defines the replacement transport for cmux mobile. It supersedes earlier experimental Iroh designs. Iroh is the default app transport. Managed relays and public direct paths bootstrap normal sessions; authenticated Bonjour can bootstrap a relayless LAN session. Tailscale and other VPN interfaces may become direct paths only after an admitted Iroh connection exchanges candidates. The released-client Tailscale TCP transport remains a separate compatibility path.

## Boundaries

cmux uses Iroh for application sessions. It does not implement a general IP VPN or expose arbitrary private-network resources. A future private-resource feature must use named, allowlisted exports through an authenticated Mac.

An Iroh EndpointID is peer identity. IP addresses, relay URLs, Bonjour records, Tailscale addresses, and VPN addresses are reachability hints only. No hint can authorize a peer, select an account, or alter a grant.

The legacy Tailscale TCP transport remains during migration for released clients and current framed RPC only. It does not receive Iroh multistream, path-migration, priority, or per-lane cancellation features. New functionality uses Iroh. Explicit relayless Tailscale and custom-VPN Iroh bootstrap require separately implemented provider-bound profiles; the wire models alone do not constitute support.

## Connection plan

Each process owns one Iroh endpoint. A peer route contains one canonical 64-character lowercase hexadecimal EndpointID and separately attributed path hints.

Production endpoints start from Iroh's `Minimal` preset and add only relays from a verified server policy. They do not use the default n0 preset or public n0 DNS address lookup. The app pins bounded Ed25519 policy keys, while the signed catalog carries relay IDs, providers, regions, and URLs. Fleet changes therefore do not require an app update. The authenticated cmux device registry is the application-specific address lookup: an endpoint publishes the signed public-disclosure subset of its current `watch_addr` value, and same-account peers resolve a known EndpointID through that registry. Private candidates stay out of the broker and are exchanged in-band only after admission. This distinction is required because an EndpointID authenticates a peer but does not say where that peer is reachable.

cmux-supplied addresses have two explicit phases:

1. Try globally routable direct addresses and the managed relay fleet. After cmux admits the peer, Iroh may exchange its own NAT-traversal candidates and migrate this connection.
2. If bootstrap fails, try an authenticated Bonjour LAN hint for the exact known Mac. Tailscale and custom-private-network explicit hints remain disabled until a production provider can prove the active overlay and bind the attempted route to it.

Private hints never enter the first cmux-supplied `EndpointAddr`. Iroh treats supplied IP paths as equivalent candidates, so array order is not a fallback boundary.

This phase split is not a relay-only IP-privacy boundary. Stock Iroh 1.0 registers a TLS-complete connection with its path manager before cmux can verify a same-account grant, then exchanges public addresses, ports, and local interface addresses. EndpointID TLS proves key possession, not cmux authorization. The pinned cmux noq, Iroh, and FFI forks therefore negotiate QUIC NAT traversal but defer candidate announcement, inbound `REACH_OUT` processing, probes, timers, and direct-path migration on each connection. Every cmux endpoint advertises zero initial bidirectional and unidirectional stream credit; the Mac raises bidirectional credit to one only for the bootstrap control stream. Admission uses an acknowledged two-phase barrier: the Mac verifies the grant and returns an accepted-pending-NAT response, the phone authorizes its exact connection and sends client-ready over the bootstrap path, then the Mac authorizes its exact connection and returns server-ready. Only that final confirmation lets the phone return a connected session. The client separately grants one unidirectional stream to the sole server-event receiver only after that receiver is prepared. Production grants bounded client application-lane credit only after server-ready. One central Mac router owns acceptance, routes terminal lanes to the terminal byte owner, and rejects artifact lanes until a concrete preview consumer registers. Every lane header has a five-second deadline. The Mac's fresh candidate advertisement reaches an already-authorized phone and starts direct-path migration on that same connection. A denial, missing acknowledgement, role-invalid frame, or authorization failure closes the connection without creating a replacement connection. Default upstream behavior remains unchanged unless these endpoint options are enabled.

After activation, the admitted peer may learn LAN, Tailscale, or other interface addresses even when cmux supplied only a relay URL. cmux documents this behavior and does not claim peer-IP concealment from an admitted peer. Iroh 1.0 still has no relay-only connection mode. Managed deployments that require peer-IP concealment must disable Iroh until a separately tested relay-only mode exists.

For admitted online sessions, this in-band candidate exchange is the generic private-network integration: Iroh can discover a working LAN or VPN interface without cmux publishing private addresses through the broker or identifying a VPN vendor. It cannot help when relay and public-direct bootstrap both fail. Explicit provider-qualified private hints are reserved for that relayless/offline case and are not production-enabled for Tailscale or custom VPNs in v1. Tailscale raw TCP remains a released-client fallback, not the model for every private network.

Path migration may move an established connection between relay and direct reachability without reopening application streams. cmux treats this as one connection and does not assume Iroh stripes bandwidth across paths.

[Upstream issue 4247](https://github.com/n0-computer/iroh/issues/4247) documents asymmetric and relay-biased path selection even when a faster local direct path exists. cmux measures the selected route class and private-path outcomes. Tests distinguish cmux-supplied hints from Iroh-discovered candidates instead of asserting that private addresses cannot affect the first connection, which Iroh 1.0 cannot guarantee.

[Upstream issue 4390](https://github.com/n0-computer/iroh/issues/4390) can multiply `pending_open_paths` without bound when at least two connections encounter persistent path-open failures, including failures from unreachable overlay hints. The pinned cmux fork carries deduplication and a hard cap, with deterministic tests that exhaust path IDs across multiple connections. Releasing an FFI artifact that pins that exact audited core revision remains a rollout gate.

Private hints expire within one hour. They use literal IP and port values, never hostnames, URLs, CIDRs, or userinfo. A hint is usable only when its provider and profile match the locally active provider profile. This prevents overlapping private address spaces from substituting one another.

The active-profile snapshot carries a network-path generation. A slow public attempt must revalidate that generation immediately before using an explicit private fallback; a VPN or interface change cancels the stale fallback instead of dialing an address from the prior network.

The wire profile identifier is a provider-qualified, 32-byte account-scoped HMAC digest encoded as canonical lowercase hexadecimal. Human network names remain local UI metadata and never enter discovery, logs, or grants.

An RFC1918, ULA, or CGNAT address does not prove which private network is active. Future explicit Tailscale profiles require Tailscale-specific interface evidence plus route binding; a text match on `*.ts.net` or `100.64.0.0/10` is insufficient. A custom profile needs an equally provider-bound proof and may require explicit user activation. If iOS cannot identify a VPN reliably, cmux does not attempt that explicit fallback. Iroh still authenticates the EndpointID after reachability succeeds.

iOS normally permits one active packet-tunnel VPN. cmux never starts a competing tunnel, and the connection UI must explain when selecting one private-network profile makes another unavailable.

The Mac exposes a stable configurable UDP listen port, or a small documented port range, for Iroh direct paths. This lets Tailscale ACLs and corporate firewalls allowlist cmux. An ephemeral-only UDP listener is insufficient for managed private-network deployments. Relay fallback remains available where UDP is blocked.

The released-client Tailscale TCP path is encrypted by the overlay but plaintext at the cmux socket layer, so it may send a Stack bearer only after proving the actual route. The phone requires a canonical numeric Tailscale IPv4 or IPv6 destination, exactly one active `utun` interface carrying a Tailscale self-address, and an `NWConnection` bound to that exact `NWInterface`. The proof carries a monotonic path generation. At connection readiness and immediately before every write, the transport rechecks the generation, satisfied path, numeric remote endpoint, and local tailnet address; any path update closes the transport before another byte is accepted. MagicDNS hostnames are display metadata in v1 and are never handed to the bearer-carrying connection. A hostname suffix, CGNAT destination, or active-VPN boolean alone is not authority.

This Tailscale proof is a compatibility hardening boundary, not cryptographic remote identity. Another packet-tunnel provider can imitate an interface name and address range, and Network.framework cannot attest that the remote node is the intended Mac. cmux therefore never extends plaintext bearer authorization to generic LAN or custom VPN routes. New clients use EndpointID TLS and pair-grant admission over Iroh.

Apple endpoints disable Iroh's automatic UPnP, PCP, and NAT-PMP port mapping. Its SSDP replies can trigger the macOS firewall dialog, and on iOS the multicast probe can request Local Network access before the user invokes LAN discovery. Hole punching and managed relays remain enabled. A future explicit port-mapping preference must explain the prompt and cannot silently restore the upstream default.

Bonjour supplies local reachability, not trust. A known EndpointID authenticates a discovered peer. First-time offline pairing requires a QR or one-time local proof. Serialized IPv6 link-local addresses are rejected because an interface scope is local to the receiving device. An IPv6-link-local-only LAN therefore requires relay reachability or a future scope-aware Iroh API; cmux does not strip a scope and risk dialing the wrong interface.

Bonjour must not advertise a stable EndpointID, account identifier, email, device name, build tag, or private-network profile. Same-account devices use a rotating opaque rendezvous alias and opaque SRV hostname derived from a backend-issued local-discovery secret and a bounded time epoch. Revocation rotates that secret. A first-time offline QR carries a separate one-use rendezvous value. The TXT record contains only its version, epoch, and interface-local numeric Iroh addresses. The phone obtains the EndpointID from its authenticated registry or QR proof before dialing, verifies the alias against that exact binding, rejects off-link addresses, then still requires Iroh TLS and a signed pair grant.

Offline LAN discovery is opt-in. The iOS target must declare its cmux Bonjour service in `NSBonjourServices`, retain a localized local-network usage reason, and browse only when reconnecting a known Mac. An admitted Iroh connection may also trigger Apple's Local Network prompt when NAT traversal tests that peer's LAN candidate. A denied connection must emit no NAT-traversal candidate or probe. Local Network denial disables Bonjour and direct LAN paths but must leave managed-relay connectivity working.

### Private-network support matrix

| Path | v1 status | Capability boundary |
| --- | --- | --- |
| Managed relay or public-direct Iroh | Supported, default | Admitted control, one server-event owner, and bounded terminal lanes; artifact lanes remain gated. |
| Iroh-discovered LAN, Tailscale, or VPN candidate | Supported after admission | Same connection may migrate direct; selection is opportunistic, not guaranteed. |
| Authenticated Bonjour LAN Iroh bootstrap | Supported | Exact known EndpointID or one-use offline proof; numeric on-link addresses only. |
| Numeric Tailscale TCP | Compatibility only | Current framed RPC after interface-bound route proof; no Iroh-only features. |
| Explicit relayless Tailscale/custom-VPN Iroh hint | Deferred | Models and tests exist, but no production provider/profile producer exists. |
| Generic LAN/custom-VPN raw TCP authorization | Unsupported | Plaintext transport cannot prove the intended Mac or safely carry a Stack bearer. |
| Relay-only peer-IP concealment | Unsupported | An admitted peer can receive private candidates; managed relays still observe metadata. |

## Authorization

Iroh's TLS handshake proves possession of the EndpointID key. A cmux pair grant proves that the two exact endpoints belong to the same Stack account and may speak `cmux/mobile/1`.

The backend issues an Ed25519-signed grant bound to both device IDs, both EndpointIDs, both endpoint generations, the ALPN, scope, issuance time, expiry, and a unique grant ID. After the QUIC handshake, the Mac verifies the signature, time window, exact local acceptor tuple, and TLS initiator EndpointID before making a broker request. An arbitrary unauthenticated peer therefore cannot use admission attempts to induce authenticated HTTP traffic.

For a locally valid grant, the Mac checks authenticated discovery for exactly one matching initiator row and one matching acceptor row. The acceptor must remain pairing-enabled, the route contract must match, and the broker relay fleet must equal the complete app allowlist. Successful snapshots are shared across concurrent admissions for at most 30 seconds. Authentication, HTTP, decoding, contract, fleet, missing-binding, and ambiguous-binding failures deny admission. Only the broker's exact connectivity error permits the locally valid signed grant to continue offline.

Every admitted session retains its signed-authority expiry and revalidates broker state at the same maximum 30-second interval, including while application streams are idle. The first revalidation deadline is measured from the snapshot fetch time, so cached admission and timer scheduling cannot extend the bound to 60 seconds. A confirmed revoke or terminal broker-policy error closes that peer connection and its child streams without recreating the process's Iroh endpoint. Connectivity failure preserves the existing connection and retries. Once a valid online snapshot proves either signed binding absent, ambiguous, or disabled, that denial remains sticky for the runtime and later connectivity failure cannot restore offline access.

Pair grants last seven days and refresh daily or when less than 72 hours remain. An admitted session closes at grant expiry even if its streams remain idle. This permits offline reconnect while bounding the window in which a continuously disconnected revoked phone can reuse a cached grant. The Mac's local pairing-disabled and device-revocation state takes precedence immediately.

The iOS offline cache is device-only and scoped to the exact Stack account, app instance, local EndpointID and generation, relay fleet, target binding, rendezvous generation, verification key set, and signed grant expiry. It is consulted only for broker connectivity failures. Authentication, TLS, HTTP, decoding, contract, relay-fleet, ambiguity, and substitution failures fail closed. Sign-out, account switch, reinstall, and identity rotation delete it. A device and Mac that remain disconnected from the broker cannot learn a new remote revocation until the signed grant expires, so seven days is the deliberate residual disconnected-revocation window.

The five-minute first-pair invitation remains one-use and requires two valid one-day same-account endpoint attestations. The Mac verifies the invitation proof, live TLS initiator, both attestation signatures, their same-account subject, and both expiries before any discovery request, then consumes the invitation. If the broker is reachable, the same exact binding, contract, complete-fleet, and pairing-enabled checks apply. Only exact connectivity permits admission offline. The resulting session expires at the earlier attestation expiry and follows the same 30-second revalidation monitor, so its residual continuously disconnected revoke window is at most one day and it cannot become an indefinitely reusable unsigned credential.

Stack bearer and refresh tokens never cross an Iroh connection. Route hints never appear in grant claims. The discovery registry is scoped to the authenticated personal account, not the currently selected Stack team.

The first control stream rejects peers without an active or locally pending grant before any application lane is accepted. The per-connection NAT-traversal gate remains closed during that check, so a denied peer receives no local candidate and cannot induce private-address probes. The first grant frame, concurrent handshakes, streams per connection, frame sizes, and unauthenticated processing time all have fixed limits. A peer is admitted only after the TLS EndpointID matches both the connection and the signed grant.

Registration requires a one-use backend challenge and a signature from the endpoint key. Endpoint rotation requires proof from the old and new keys. Lost-key recovery creates a new endpoint and requires reapproval.

## Identity lifecycle

The endpoint secret is a 32-byte Ed25519 key stored with `AfterFirstUnlockThisDeviceOnly` data protection. It is not synchronized or backed up. Account switching rotates the key. Because Keychain items can survive app deletion, an app-container installation marker detects reinstall and rotates any surviving key before registration.

Identity generation and runtime generation are separate values. Identity generation changes only when the key or account binding changes and is included in registration and grants. Runtime generation changes whenever an endpoint instance is recreated and remains local, where it rejects stale async results. Foreground recreation must not invalidate a cached offline grant.

iOS may suspend networking in the background, but cmux does not proactively close a healthy endpoint or its established QUIC streams on every background transition. It stops nonessential discovery and refresh work while preserving the live endpoint for as long as the OS permits. Foreground activation first checks the existing generation; if the OS terminated or invalidated it, cmux recreates the endpoint from the same secret, preserves EndpointID, then redials and resumes streams from application cursors. Every async result is generation-checked so an old endpoint cannot mutate new state.

[Upstream issue 4289](https://github.com/n0-computer/iroh/issues/4289) shows that a failed UDP rebind after iOS resume can silently terminate the EndpointDriver without surfacing an API error. cmux requires an endpoint-health watchdog. A terminal health failure recreates the endpoint from the same key and identity generation while advancing the runtime generation, then resumes application streams from their cursors.

The fork must expose cancellation for an in-progress connect. Closing a QUIC connection unblocks established stream reads, but it does not reliably cancel the current FFI handshake bridge.

## Relay fleet and preferences

`config/iroh/managed-relay-catalog.json` is the committed, server-owned source of truth for the managed fleet. `web/tools/generate-managed-iroh-relay-catalog.ts` validates it and writes the generated TypeScript consumed by the web API and presence worker. Build checks reject generated-file drift. Managed relay URLs do not come from deployment environment variables, and signing keys and relay credentials never enter the catalog or generated files.

Every catalog has a strictly increasing sequence and at most sixteen unique credential-free HTTPS origins. The backend rejects sequence rollback and same-sequence content changes. It signs a five-minute policy with an Ed25519 key whose public half is pinned by clients. A cached policy remains usable only until its signed expiry. Invalid, expired, rolled-back, or unverifiable policy fails closed to direct Iroh paths. Fleet rotations are add-before-remove: bump the sequence and add relays, regenerate and deploy both server consumers, wait at least one signed-policy lifetime, then bump the sequence again before regenerating, deploying, and removing the retired relays. A stable relay ID never changes meaning in place.

The server may add, remove, or replace relays without a client update. A remote `EndpointAddr` contains only the remote endpoint's advertised home relay or relays, validated against the signed fleet. Fleet configuration and remote reachability remain separate wire fields.

A signed-in native client calls `POST /api/relay/token` with its canonical EndpointID. The web API returns a five-minute endpoint-bound relay JWT, the signed policy, and the account preference. Each cmux relay verifies its JWT offline. The app refreshes before expiry and replaces the verified relay policy on the live endpoint without changing EndpointID or application streams.

Relay preferences are personal-account scoped:

- Automatic uses every relay in the current verified cmux fleet.
- Selected cmux relays uses only the chosen stable relay IDs. If every selected ID disappears, cmux stays direct-only instead of substituting a relay.
- Custom relays uses only the account's custom relay metadata. Managed relays never become a fallback in this mode. HTTPS origins sync across same-account devices; provider credentials stay in device-only Keychain storage. A device missing its required credential stays direct-only.

Preference writes use optimistic revisions, reject credentials in every server field, and are rate-limited by account. The Mac and iOS Settings screens expose the same account preference, managed selection, custom metadata, credential state, policy source, stale selection, and refresh action.

Tagged Debug builds pin the staging policy key; Release builds pin the production key. Both consume the server-signed self-hosted fleet through the same provider-neutral policy and endpoint-bound credential contract. Every deployed relay enforces per-EndpointID and per-account connection caps plus per-connection traffic limits, so creating more EndpointIDs cannot bypass the account resource bound. Relays close each authenticated connection at its signed expiry. Expiry tasks are keyed by process-unique relay connection IDs, so an old credential's timer cannot close a refreshed connection for the same EndpointID. The previously pasted Iroh Services API key is unused by the self-hosted fleet and must still be rotated because it was disclosed.

[Upstream issue 4319](https://github.com/n0-computer/iroh/issues/4319) reports roughly 30 seconds of lost reachability after a custom home relay fails even when another relay is configured. Relay failover and rolling restarts require a soak and telemetry gate that measures inbound-reachability gaps, stream survival, and recovery latency. cmux does not claim relay high availability until those bounds pass.

No n0 public DNS discovery or development relay enters the production preset. Relay URL syntax validation is separate from the runtime allowlist above.

Iroh 1.0 relay-over-WebSocket does not honor a system HTTP proxy. A network that permits outbound traffic only through an explicit HTTP CONNECT proxy may therefore make every Iroh route unavailable even though ordinary HTTPS works. cmux retains the released-client Tailscale TCP transport for this case and reports the Iroh failure. Generic LAN or custom-VPN plaintext TCP is not an authenticated substitute. Proxy-only Iroh support remains gated on an upstream transport hook or a reviewed fork implementation.

End-to-end encryption does not hide connection metadata. A relay can observe source and destination IP addresses, endpoint identifiers, timing, and relayed byte counts. A direct peer learns the other peer's reachable IP address. cmux must disclose this in privacy documentation and must not enable Iroh Services network-diagnostics capabilities without explicit user consent. Relay-only peer-IP privacy is not a v1 launch claim.

The app derives path quality from local Iroh connection statistics. Product telemetry may report aggregate route class, relay region, latency bucket, reconnect result, and byte bucket, but never IP addresses, private hints, full EndpointIDs, grants, or tokens. The Iroh Services project API secret is not embedded to obtain diagnostics or dashboard metrics.

## Streams and capabilities

The initial ALPN is `cmux/mobile/1`. Production v1 multiplexes:

- a control stream for grants, requests, and lifecycle messages;
- one centrally owned server-event stream with sequence cursors;
- bounded terminal streams with resource IDs, priorities, replay cursors, and one central Mac accept owner.

The binary protocol also reserves client-created bidirectional artifact lanes. Production rejects them until the preview feature supplies a concrete owner. Server-created artifact streams remain disabled because the iOS unidirectional accept owner routes only server events. Artifact preview should use a client-created artifact stream, which lets the requesting feature own both halves without competing for an accept loop.

Datagrams carry only disposable hints. Mutating requests never use 0-RTT.

The official Swift FFI exposes raw QUIC connections, bidirectional and unidirectional streams, datagrams, relays, and connection statistics. It does not expose every Iroh protocol crate. cmux maintains a minimal fork for Apple platform support, cancellation, and required bindings. Blobs, documents, and gossip are added incrementally with protocol-level tests. Large resumable verified artifacts are a likely blobs use case; latency-sensitive previews should first use low-priority streams on the existing connection. Iroh 1.0 has an open single-stream blob-throughput regression on LAN, so artifact adoption requires chunking and measured end-to-end throughput rather than assuming the typed protocol is faster. Gossip and docs each require their own memory, persistence, compaction, and mobile-energy soak before product use.

## Disclosure and persistence

cmux-supplied private and local path hints may travel only through an authenticated same-account channel. Iroh's own private candidates are exchanged only after the per-connection same-account admission gate opens. Both forms are excluded from identity-only pairing QR payloads, public host status, logs, support bundles, public discovery, and cloud backup. Public host status returns zero attach routes. Persisted routes prune expired hints. Logs use classifications or keyed hashes, never full EndpointIDs, relay tokens, grants, or private addresses.

Pairing QR encoding requires an explicit disclosure mode. `irohIdentityOnly` keeps only the Iroh EndpointID and removes every path hint, host/port route, token, and URL route. It is the production default whenever an Iroh route exists. The Mac can separately generate a user-invoked `legacyPrivateNetworkCompatibility` QR for released clients that still require Tailscale or another private-network address. If Iroh is unavailable, the compatibility QR remains the only supported path; loopback alone is never considered pairable.

Application-layer reachability can bypass DNS filters or network-layer allowlists. Managed deployments need an MDM/configuration policy that can disable Iroh, restrict it to approved relay URLs, or require the legacy private-network path. cmux does not disguise relay traffic or create an alternate way around an administrator's access policy.

Future connection UI may report app transport and observed outer provider separately, for example `Iroh via Tailscale`, only after the FFI exposes enough selected-path metadata to support that classification. It is not a v1 claim. A Tailscale path may itself use DERP, so cmux must never infer a direct physical path from a Tailscale address alone.

Public direct hints must be globally routable. Direct values reject loopback, unspecified, multicast, broadcast, metadata endpoints, ambiguous numeric forms, and IPv6 link-local wire values. Managed relay URLs require root HTTPS URLs and a runtime allowlist match.

## Release gates

Before defaulting to Iroh, verification must cover:

- arm64 and Intel macOS, including macOS 14.0;
- arm64 iOS devices and arm64/x86_64 Simulators;
- public direct, managed-relay, post-admission NAT-traversed LAN/Tailscale/custom-VPN candidates, authenticated Bonjour LAN bootstrap, and hardened numeric Tailscale TCP compatibility paths;
- TCP-only firewalls, blocked UDP, captive portals, constrained paths, and expensive cellular paths;
- explicit HTTP-proxy-only networks, with a clear legacy/private-network fallback until Iroh relay WebSockets support proxy-controlled connection establishment;
- relay token denial, expiry, refresh, and long-lived stream preservation;
- background and foreground endpoint recreation with stable EndpointID;
- a deterministic failed-rebind/network-resume test that proves the health watchdog detects terminal driver failure and recreates the endpoint from the same key and identity generation with a new runtime generation;
- a malicious pre-admission QNT peer, proving zero candidate disclosure, `REACH_OUT` probes, timers, or migration before activation and same-connection migration after both admitted sides activate;
- admission-barrier ordering, proving zero initial stream credit, one bootstrap stream, no application lane before server-ready, and no server-side NAT activation after denial, timeout, cancellation, an invalid frame, or a missing client-ready frame;
- measured direct, relay, Bonjour fallback, and post-admission native private-path selection, including asymmetric traffic and classification of cmux-supplied versus Iroh-discovered candidates;
- numeric Tailscale TCP bearer tests that prove zero token bytes on VPN-off, wrong or multiple interfaces, carrier CGNAT, stale path generation, route-kind substitution, endpoint mismatch, and queued-write races;
- long-lived multi-interface and VM-bridge connections, checking periodic path churn, battery use, congestion resets, and accidental relay selection;
- the pinned Iroh core's `pending_open_paths` deduplication and hard cap, plus an adversarial multi-connection test with failing overlay hints that asserts bounded queue and memory growth;
- custom-home-relay failure and rolling-restart soaks with bounded reachability and stream-recovery telemetry;
- regional relay instance loss and capacity exhaustion, because one relay per region is currently one regional failure domain even though other regions can recover reachability;
- a long-running Router soak with tracing enabled and idle adversarial connections, guarding against the span accumulation in [upstream issue 3963](https://github.com/n0-computer/iroh/issues/3963);
- same-account grant success plus cross-account, swapped-peer, revoked, expired, and replay denial;
- coalesced online admission refresh, sticky learned revocation, idle-session closure within 30 seconds of an observable revoke, connectivity preservation, and closure at grant expiry without endpoint recreation;
- offline cached-grant reconnect and explicit first-time offline pairing;
- control and server-event stream fairness, cancellation, and reconnect cursors; terminal and artifact backpressure before either reserved lane is production-enabled;
- mobile energy use, relay byte use, and Low Data Mode behavior;
- a final security and privacy pass over wire data, persistence, logs, and backend abuse limits.

GitHub's hosted `macos-14-large` runner provides the required Intel Sonoma lane today, but GitHub began deprecating macOS 14 images on July 6, 2026 and plans to remove them on November 2, 2026. cmux must move this release gate to an Intel lab runner before that date rather than silently dropping macOS 14 coverage.

Current regional capacity is provisional until fresh PostHog geography data is available. The stale sample suggests the existing US, EU, and AP coverage is reasonable, but Tokyo or Seoul may merit an additional relay after a current query.
