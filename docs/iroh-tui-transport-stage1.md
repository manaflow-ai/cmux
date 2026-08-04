# Iroh TUI transport, stage 1

Status: design accepted for stage-1 implementation, August 2026. Parent architecture: [iroh-app-transport-architecture.md](iroh-app-transport-architecture.md), which binds identity, admission, relay policy, and disclosure rules for every cmux iroh peer. This stage makes a `cmux-tui` session server an admitted iroh peer: reachable from anywhere, including a Docker container behind NAT with zero inbound ports, dialed by EndpointID alone through the account device registry.

## Shape

One new sidecar crate, `cmux-tui/crates/cmux-tui-iroh`, producing a `cmux-tui-iroh` binary with three roles. The `cmux-tui` binary and `cmux-tui-core` are unchanged; every integration goes through seams the specs already define.

- `cmux-tui-iroh enroll` exchanges a one-use provisioning token for a device credential and mints the device identity into the cmux-tui state root.
- `cmux-tui-iroh listen` registers the device with the broker, binds one iroh endpoint, and bridges each admitted stream to the local session Unix socket as a protocol v10 JSON-lines client. The wire schema is byte-for-byte the existing v10 contract; iroh replaces `ssh -T ... cmux-tui relay` in the relay-stdio pattern from `cmux-tui/spec/transports.md`.
- `cmux-tui-iroh provider` implements machine-provider v1 over stdio (`cmux-tui --machine-provider-command cmux-tui-iroh provider --`). The control role resolves account devices from the broker registry into the machine rail; `open_machine` mints a pair grant and a one-use ticket; the stream role returns reader/writer halves that `RemoteSession` consumes per the v1 contract in `cmux-tui/spec/machine-provider.md`.

Web (separate PR): a one-use enrollment-token mint/exchange route pair, the `linux` platform value for iroh endpoint bindings, and a TUI pair-grant profile.

## Relationship to cmux-remote

`crates/cmux-remote` already ships a remote daemon (`cmux-tui daemon --iroh`) that can use iroh as one carrier among several. It is deliberately a different trust system: admission is daemon-local Noise device enrollment with interactive owner approval, the iroh EndpointID is "a route credential, not daemon authorization" (`spec/remote-daemon.md`), the wire is Noise-encrypted CMXL lanes rather than plain protocol v10, and its iroh endpoints run `RelayMode::Default`, the n0 public relays the transport architecture forbids for production cmux peers. It has no broker client, no account identity, and no headless enrollment (approval is hardcoded interactive).

Stage 1 does not modify cmux-remote. It adds the account-scoped, arch-conformant transport as a sidecar with a distinct ALPN (`cmux/tui/1` vs `dev.cmux.remote/1`) and its own endpoint key, so the two coexist without interference. Convergence is explicitly stage-2+ work: cmux-remote could gain a pair-grant authorization mode next to Noise enrollment, and its `IrohProviderConfig` already accepts `RelayMode::Custom`, so the managed-fleet-with-auth-tokens wiring built here is directly portable. Until then, the sidecar is the only cmux-tui iroh path that satisfies the architecture doc's relay and admission rules.

## Architecture constraint mapping

Each row is a binding rule from the arch doc and the stage-1 implementation choice.

| Arch constraint | Stage-1 choice |
| --- | --- |
| Each process owns one iroh endpoint | `listen` owns one endpoint. The provider control process owns one endpoint; per-ticket stream processes do not bind a second endpoint on the same key, they rendezvous to the control process over a private 0700 Unix socket and the control process opens one fresh bi-stream per ticket on its single connection. |
| `Minimal` preset, verified relays only, never n0 defaults or public DNS discovery | `Endpoint::builder(presets::Minimal)` + `RelayMode::Custom` built from `config/iroh/managed-relay-catalog.json` (compiled in from the committed server-owned source of truth). No discovery service is configured; no relay URL comes from the environment. |
| EndpointID is identity, hints are reachability only | The dial address is `EndpointAddr::from_parts(endpoint_id, full verified fleet as relay transports)`. The EndpointID comes from the authenticated discovery registry; no address in the registry authorizes anything. Proven against the fleet in the testbed (`tbcore/tests/catalog_dial.rs`): connect by id plus catalog with no knowledge of the home relay, 175 ms. |
| Signed relay policy, pinned Ed25519 policy keys | Deferred, documented gap: stage 1 compiles in the committed catalog instead of verifying the signed policy JWS from `POST /api/relay/token`. The catalog and the policy have the same source of truth, so fleet content is identical; rotation during a long listener run is not picked up until restart. Stage 2 verifies the signed policy with pinned keys and refreshes the live relay map. |
| Registration requires a one-use backend challenge and an endpoint-key signature | Direct port of the shipped flow: `POST /api/devices/iroh/challenge`, Ed25519 signature over the `cmux/iroh/device-registration/v1` transcript, `POST /api/devices/iroh/register`. Platform `linux`, `pairingEnabled: true`, `pathHints: []`, no direct ports. |
| Stable (user, deviceId, tag) slot; reboots re-register idempotently | First boot mints a 32-byte Ed25519 endpoint key and a deviceId UUID, persisted with the provisioning-supplied tag in the state root. A restart replays registration with the same tuple and unchanged endpoint key, which the broker treats as a heartbeat update-in-place on the same slot (same binding id, existing grants keep resolving). |
| Endpoint secret storage (`AfterFirstUnlockThisDeviceOnly` on Apple platforms) | Linux containers have no Keychain. The identity file lives at `<state root>/device/iroh-identity.json` with the same hardening as the existing durable-notice identity: 0700 parent, 0600 file, `O_NOFOLLOW`, flock lease, atomic create. The state volume is the trust boundary; cloning a volume clones the identity, which the broker surfaces as slot conflicts. Provisioning must not clone state volumes. |
| EndpointID TLS proves key possession, not cmux authorization; admission requires a same-account pair grant | The first bi-stream on every connection must carry one admission frame with a broker-signed pair-grant JWS before anything else. The listener verifies: EdDSA signature against the broker-distributed grant verification keys, `typ`, time window, `alpn = cmux/tui/1`, `scope = cmux.tui.attach`, acceptor binding matches self (endpointId and deviceId), initiator endpointId equals the TLS peer identity. Only the broker mints grants and only for two active same-account bindings, so a valid grant is the same-account proof. Any failure closes the connection. |
| Admission barrier (zero stream credit, deferred NAT candidates, two-phase ready) | Bounded stage-1 subset, auth-equivalent but not privacy-equivalent. Enforced: no protocol dispatch before grant verification, one admission frame capped at 16 KiB with a 5-second deadline, bounded concurrent unadmitted connections, deny closes the connection. Not ported: the pinned-fork QUIC NAT-traversal deferral and stream-credit gating, which do not exist in upstream iroh 1.0.3. Consequence: a peer that knows the EndpointID can complete TLS and may observe NAT-traversal candidates (container-local addresses) before being denied. This weakens the privacy property, not the authorization property; stage 2 adopts the pinned fork. |
| Admitted sessions revalidate broker state at most every 30 seconds | While admitted connections exist, the listener polls authenticated discovery every 30 seconds. A missing or revoked initiator or acceptor binding closes the affected connections. Broker connectivity failure preserves connections and retries, matching the arch rule that only confirmed revocation tears down. Grant expiry closes the session. |
| Grant verification keys | Fetched from the authenticated discovery response (`grant_verification_keys`), cached in the state root, refreshed at startup and on each revalidation poll. Never fetched from an unauthenticated channel. |
| Relay tokens: 300 s endpoint-bound JWT, established websockets never re-authenticated, mint quotas | Testbed-proven lifecycle: cache tokens with more than 90 s of life, rotate lazily only after two consecutive failed relay-status checks (about 30 s) via `remove_relay` + `insert_relay`, respecting the 3-per-10-minute and 12-per-day mint quotas. |
| Disclosure: no private hints in broker, logs use hashes, tokens never logged | Registration publishes no path hints and no ports. Logs print 8-hex keyed prefixes of EndpointIDs, never grants, tokens, or credentials. The enrollment token and device credential are read from an env var or 0600 file, never argv. |
| Headless enrollment | No interactive Stack sign-in exists in a container. A signed-in user mints a one-use enrollment token (new route, hashed at rest, 15-minute TTL). Provisioning injects it; `enroll` exchanges it once for a Stack session pair (the existing vault CLI device-flow precedent, `user.createSession`), persisted 0600 in the state root. The credential is account-scoped like every existing CLI credential; narrowing to a device-scoped credential is stage-2 work and is why the exchange is isolated behind one route. |

## Web changes

1. `POST /api/devices/iroh/enrollment-tokens` (authenticated, native Stack bearer): mints `{token, expires_at}`; stores `sha256(token)` with userId, 15-minute expiry, single use.
2. `POST /api/devices/iroh/enroll` (unauthenticated): body `{token}`; constant-time hash lookup, unexpired, unconsumed; consumes it and returns a Stack session `{accessToken, refreshToken}` minted for the token's user, mirroring `vault/cli/auth/poll`.
3. Platform `linux`: type and validator in `services/iroh/model.ts`, DB CHECK migration for `iroh_endpoint_bindings`, `PairGrantPeer`/attestation platform literals in `crypto.ts`, `bindingPlatform` in `trustBroker.ts`, repository input types.
4. TUI pair-grant profile, selected by acceptor platform so the request body stays `{initiatorBindingId, acceptorBindingId}`: acceptor `linux` with `pairingEnabled` requires initiator platform in `{mac, ios, linux}` and mints `alpn: cmux/tui/1`, `scope: cmux.tui.attach`. Acceptor `mac` keeps the existing ios-to-mac mobile profile unchanged. The profile rule is enforced at all three existing layers (route gate, repository, claims validation) like the mobile rule.

## Client leg

The frontend device (the Mac running the TUI) enrolls and registers exactly like the server device, with platform `mac` and `pairingEnabled: false`. The provider control process builds the machine rail from discovery rows with platform `linux`, requests a pair grant per `open_machine`, dials by EndpointID plus fleet, performs admission on the first stream, and hands each subsequent per-ticket stream to a stream-role process over the private rendezvous socket. `RemoteSession` receives complete JSON-lines messages within the v1 64 MiB frame bound, unchanged.

## Authority class

Bridged iroh clients terminate at the session Unix socket and therefore carry Unix-class authority, including `shutdown-daemon` and `pairing-response`, identical to the documented SSH relay-stdio model. Access is limited to same-account paired devices by admission. A reduced-authority relay profile remains the open item `spec/transports.md` already names.

## Acceptance (stage-1 exit)

`cmux-tui --headless` plus `cmux-tui-iroh listen` in a Linux Docker container behind NAT with zero published ports and a named state volume. From the Mac: enroll a frontend identity, run `cmux-tui --machine-provider-command cmux-tui-iroh provider --`, select the container machine, attach, run commands. Detach and reattach preserves the session. `docker restart` re-registers the same (user, deviceId, tag) slot with the same EndpointID and the machine is attachable again without re-enrollment. Captured as a script plus recorded terminal evidence.

## Explicitly deferred

Signed relay-policy verification with pinned keys and live fleet rotation; the pinned iroh fork's pre-admission candidate suppression; a device-scoped (non-account) credential; a reduced-authority remote profile; relay preference support; Mac/iOS app frontends attaching to TUI sessions (stage 2+ of the program).
