# Transport v3 security audit, current revision

Scope: Rust grants, Cedar authority, HTTP control service, libp2p session/relay path, UniFFI boundary, Swift grant client, Azure relay image and staging NSGs. Review date: 2026-09-17. This is a pre-production audit; the remaining items below are release blockers.

## Resolved controls

- Stack is the server-side source of user, team and administrator identity. Client claims cannot assign owner, tags, lease, role or source peer.
- Cedar evaluates a coherent, tenant-scoped device snapshot. The default policy is directional for connect, terminal read and terminal write. Unlimited offline access requires a separate `offline_unlimited` decision.
- Device proofs use domain separation, deployment audience, HTTP method/path, user, UUID nonce, issue time and canonical sorted JSON payload. PostgreSQL consumes each nonce atomically.
- Grants are Ed25519 JWTs with exact issuer, audience, source, destination, team, action, policy revision and lease checks. Finite deadlines use the authority verification timestamp. `until_revoked` cannot be encoded by omitting a finite expiry.
- Policy and device mutations serialize on a team row and use expected revisions. Event storage has a global relay cursor and a contiguous team-local revocation sequence. A first or later sequence gap is rejected.
- Relay authorization binds the Noise-authenticated source and destination to the signed grant. Reservations and circuits are team scoped. Forged grants, cross-team destinations and wrong directions are denied.
- Session input is bounded at every layer. Hello, frame, queue, concurrent session, connection, relay reservation, circuit and cached-permit limits are explicit. Expiry/revocation cancels blocked I/O and buffered data is rechecked before delivery.
- Swift sends Stack bearer tokens only to the configured HTTPS control origin. Endpoint signing material and transport identity are device-only Keychain items. Native ownership and cancellation remain inside generated UniFFI handles.
- Relay containers run without capabilities, with a read-only root, no-new-privileges, non-root UID, bounded CPU/memory/PIDs, digest-pinned images and a managed identity limited to ACR pull. Management binds to loopback and public NSGs do not expose SSH, management or internal WebSocket ports.
- Dependency audit reports no selected known vulnerability. Hickory advisories were removed through the in-org libp2p fork. `paste` remains an allowed unmaintained dependency warning.

## Verification performed

Rust tests, strict Clippy, browser WebSocket interop, Swift v3 package tests, iOS target compilation, explicit disposable-Postgres migrations through `0003`, and Python deployment/upgrade/observability tests pass. Staging East US and West US 2 relay generations pass authenticated TCP, QUIC and WSS application probes. Azure Monitor outage detection fired and resolved while relay traffic continued. Old generations drain and exit with code zero.

## Release blockers and residual risk

1. The control service is not deployed against a PlanetScale branch. Until that happens, relay feed registration and cross-region revocation are only local tests.
2. The production iOS and Mac composition roots still default to IRX/iroh. The Mac has only an opt-in v3 control-lane host; no release can claim replacement until v3 discovery, all host lanes, renewal, revocation, reconnect and sign-out run on physical devices.
3. Relay handover was observed with a live probe, but the relay circuit gauge was zero at the drain observation. A non-empty circuit plus application replay and terminal-input execution acknowledgements is required.
4. DCUtR is composed but real NAT traversal, blocked UDP, network roaming, app suspension and airplane-mode recovery have not been proven.
5. Per-team circuit and byte quotas, latency/byte histograms, continuous synthetic probes, notification action groups and certificate-expiry checks are not yet complete.
6. Authority key rotation and relay feed-token rotation need an operational procedure with overlap and rollback evidence. Key changes must never be delivered through an unauthenticated endpoint.
7. The relay feed currently starts at sequence zero and intentionally fails closed on a missing prefix. Production must retain the complete event history or provide a signed snapshot bootstrap before pruning.
8. A full mobile threat review remains necessary for route disclosure, Keychain accessibility, background execution and stale directory hints after the app switch.

No production database, production relay, public anycast route or user notification destination was changed during this audit.
