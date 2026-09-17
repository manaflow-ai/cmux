# Transport v3 foundation

Independent Rust workspace for replacing iroh. Azure staging relays in East US
and West US 2 pass authenticated application-stream tests over TCP, QUIC and WSS.
The Rust control service and native stream core are implemented but not wired
into either app. See IMPLEMENTATION.md for evidence and remaining requirements.

## Boundaries

- `cmux-v3-grants`: Ed25519 JWT permissions, finite/infinite leases, local
  verification, and monotonic policy-revision/device revocation enforcement.
- `cmux-v3-authority`: server-side Cedar evaluation over a coherent team
  snapshot. All device records, tags, membership, and timing come from trusted
  storage. The caller must supply an authenticated source key.
- `cmux-v3-transport`: native libp2p QUIC, Noise/Yamux over TCP/WebSocket,
  Circuit Relay v2, DCUtR and generic streams. The session protocol bounds
  admission to 16 KiB, application frames to 64 KiB and queues to eight frames.
  Signed renewal requires receiver acknowledgment; expiry and revocation cancel
  blocked I/O. Terminal read and input lanes require their corresponding grants;
  a read lane cannot carry initiating-peer data. There are no legacy dependencies.
- `cmux-v3-control-server`: Stack identity/team/admin verification, signed device
  proofs, enrollment, Cedar policy and device timing, and atomic PostgreSQL writes.
- `cmux-v3-relay-server`: signed-grant admission for reservations and device pairs,
  bounded grant cache, private management credentials, readiness/metrics, and
  draining that refuses new circuits while renewing still-live cached permissions.
  The process test exercises a real encrypted circuit through the actual binary.
- `interop`: Chromium using JS libp2p through a loopback Rust relay to a Rust
  host, with both an allowed exchange and an invalid-grant rejection.

Team membership is checked before ACL evaluation by constructing snapshots
containing only enrolled devices from one team. The default Cedar policy
allows both directions for connect, terminal read, and terminal write.
Applications still need to enforce the selected action at their RPC boundary.

## Configurable offline authorization

Each device record resolves to an administrator-controlled lease policy.
The storage adapter will apply team defaults and user/device overrides.

```json
{"offline":{"mode":"bounded","seconds":300},"renew_every_seconds":30}
```

Unlimited offline access is explicit:

```json
{"offline":{"mode":"until_revoked"},"renew_every_seconds":30}
```

The authority additionally requires Cedar permission for `offline_unlimited`.
For example, append this to the team's policy to enable the configured
unlimited lease for devices owned by a selected immutable Stack user ID:

```cedar
permit(principal, action == Action::"offline_unlimited", resource)
when { principal.owner == "stack-user-id" };
```

Missing fields, zero durations, renewal intervals at least as long as finite
leases, unknown fields, and inconsistent signed expiry are rejected.
Finite expiry is based on the snapshot's verified-at time, not when a stale
region issues a grant. `usable_until` separately bounds whether a regional
snapshot may authorize anything, including new unlimited grants.

An unlimited grant has no offline revocation bound. Receiving a newer policy
revision or a device revocation still invalidates it. Changing an unlimited
policy to finite cannot reach disconnected peers retroactively. Refresh remains
configured so online devices can receive changes; the scheduler is not implemented.

## Verification

Run on a leased fleet machine or hosted CI, not the shared local Mac:

```sh
cd services/transport-v3
cargo fmt --all --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
cargo build -p cmux-v3-transport --example browser_fixture --locked
cd interop
npm ci
npx playwright install chromium
npm test
```

Apple target verification from the workspace root:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
cargo build -p cmux-v3-transport --lib --target aarch64-apple-ios --locked
cargo check -p cmux-v3-transport --target aarch64-apple-ios-sim --locked
```

The browser fixture accepts only the chosen browser and host PeerIds, binds to
127.0.0.1, uses ephemeral peer keys, and exits after 90 seconds. Its deterministic
test signing key must never be used outside the fixture. WebSocket is plaintext
on loopback; Noise encrypts the peer exchange end to end. Public WSS/TLS is not
verified by this fixture.

## Remaining integration

1. Deploy and connect the Rust HTTP authority to Stack and persistent storage.
   Current cmux Cloud storage is PlanetScale Postgres; no Azure database has
   been provisioned and no production/staging schema has been changed.
2. Durable, tenant-scoped records and a recoverable authorization update feed.
   Cache freshness must include membership and device revocations, not just
   ACL text. Persist known revocations and signer trust across app restarts.
3. Per-team active bandwidth/circuit quotas, revocation delivery, and sustained
   load tests. Public TLS and authenticated application transfer are verified.
   Destination-aware admission uses the
   small in-org fork hook in https://github.com/manaflow-ai/rust-libp2p/pull/1
   (author lawrencecchen). Do not deploy the laboratory relay or untested scripts.
4. Endpoint lifecycle, grant-fetch scheduling, relay selection and handover.
   The stream owner now enforces expiry/revocation independently of blocked I/O,
   accepts acknowledged renewal and rejects permission rollback. Application
   acknowledgments, replay and safe restored deadlines remain separate work.
5. Swift bindings, Keychain identity, iOS lifecycle, reconnect/replay and input
   acknowledgment. Target compilation is not iPhone runtime verification.
6. Backup reservations, overlapping-generation handover and rollback proof,
   cross-region revocation tests, and the selected database failure model.
7. Real NAT hole-punch tests, blocked UDP, network switching, and suspended-app
   recovery. DCUtR is composed but not proven by loopback tests. Direct browser
   WebRTC is also unverified. No automatic stream migration is claimed.

No v2 compatibility, WireGuard VPN interface, new Durable Object, DHT, or
gossip discovery is introduced. The existing apps retain their current runtime
until v3's replacement path is implemented and verified.
