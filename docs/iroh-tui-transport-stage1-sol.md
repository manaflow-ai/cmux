# Iroh transport for cmux-tui, Stage 1

Status: implementation design for the independent `feat-iroh-tui-transport-sol` attempt.

This stage makes one existing cmux-tui session socket reachable through iroh by EndpointID. It keeps protocol v10 JSON-lines unchanged after a transport admission exchange. It intentionally uses managed relays only. Direct UDP, hole punching, LAN discovery, private candidate exchange, and offline admission remain outside Stage 1.

The broker contract is the contract in [manaflow-ai/cmux#9515](https://github.com/manaflow-ai/cmux/pull/9515): Linux endpoint registration, TUI pair grants with ALPN `cmux/tui/1` and scope `cmux.tui.attach`, and one-use headless enrollment tokens. This transport consumes that contract and does not add competing web routes or persistence.

## Stage 1 boundary

The transport consists of a small Rust sidecar and library in the cmux-tui workspace:

- `cmux-tui-iroh server` owns one persistent Linux iroh endpoint, registers it, admits one broker-authorized stream at a time, and proxies admitted bytes to an existing local cmux-tui Unix socket.
- `cmux-tui-iroh provider` exposes a machine-provider v1 Unix socket on the frontend machine. It registers its own endpoint, resolves Linux account devices through the broker, issues one-use provider tickets, obtains a pair grant, dials the selected EndpointID, and proxies the admitted stream to the frontend.
- `cmux-tui-iroh enroll` exchanges a one-use provisioning token for a persisted credential pair without placing the provisioning token on an iroh stream or in durable state.

The sidecar is a transport adapter. The session owner stays the existing cmux-tui server, and every byte after admission is its existing protocol v10 JSON-lines stream.

Stage 1 configures `iroh::endpoint::presets::Minimal`, a custom relay map built only from a verified broker policy, and `clear_ip_transports()`. No n0 preset, n0 discovery, public n0 DNS, direct address, LAN discovery, or environment-supplied relay URL is reachable in this mode. Relay-only operation also means stock iroh 1.0.3 has no private candidate to disclose before pair-grant admission. Direct path migration will require the accepted pre-admission candidate barrier before it can be enabled.

## End-to-end flow

### First enrollment and registration

1. `enroll` opens or creates the selected cmux-tui iroh state directory with owner-only access.
2. It creates `endpoint.key` through `cmux_remote::provider::load_or_create_iroh_secret` and creates metadata containing a client-minted `deviceId`, `appInstanceId`, provisioning tag, and identity generation 1.
3. It reads the one-use provisioning token from an owner-only file or inherited standard input, posts exactly `{ "token": ... }` to `POST /api/devices/iroh/enroll`, zeroizes the token buffer, and stores the returned access and refresh tokens in an owner-only credential file.
4. Server or provider startup calls `POST /api/relay/token` for its EndpointID. The unbound bootstrap response supplies the signed relay policy. The client verifies the compact Ed25519 JWS against the selected built-in trust root and the complete policy schema before accepting any relay URL.
5. Startup serializes one canonical registration payload, hashes those exact bytes, obtains a challenge from `POST /api/devices/iroh/challenge`, signs the specified registration transcript with the endpoint key, and posts the signed payload to `POST /api/devices/iroh/register`.
6. Startup calls `POST /api/relay/token` again. It requires one endpoint-bound credential for every relay in the verified policy and no extra credential. Only then does it bind the iroh endpoint.

The registration payload uses platform `linux` for a server and the local frontend platform for a provider. The server advertises capability `cmux.tui.attach`, enables pairing, and publishes no path hints in Stage 1. The provider does not enable pairing. Empty path hints are intentional because the remote address is reconstructed from the authenticated EndpointID plus the locally verified relay catalog.

The broker serializes registration by `(userId, deviceId, tag)`. Reusing the persisted endpoint key, device ID, app instance ID, tag, and generation therefore updates the same active binding in place. A container restart never mints a new identity when its state volume remains mounted.

### Provider discovery and open

1. A frontend connects to the owner-only provider Unix socket. Its first control frame is machine-provider `hello` with a fresh generation bearer.
2. `snapshot` fetches every broker page, requires one coherent revision and relay fleet, and returns active pairable Linux bindings as machine descriptors in one personal scope.
3. `open_machine` refreshes discovery, locates the frontend's exact initiator binding and selected Linux acceptor binding, obtains a TUI pair grant, and creates a random in-memory provider ticket valid for 30 seconds.
4. The result is `TransportDescriptor::ProviderStream { ticket, expires_at }` with a provider connection ID.
5. The frontend opens another provider socket and sends the required `TransportHandshake` with role `transport`, its generation bearer, and the ticket. The provider compares the bearer in constant time and atomically consumes the ticket.
6. The provider builds an `EndpointAddr` containing only the acceptor EndpointID and every relay URL in the verified catalog, dials ALPN `cmux/tui/1`, and verifies `connection.remote_id()` equals the requested acceptor EndpointID.
7. The provider sends one bounded transport admission frame containing the pair grant. It waits for the server admission acknowledgement, returns `TransportHandshakeResult { accepted: true }` locally, then copies bytes in both directions without interpreting protocol v10.

Tickets are generation-bound, machine-bound, one use, and memory-only. Expiry, control-generation replacement, `close_machine`, local stream closure, or provider exit closes the corresponding upstream connection.

### Server admission

1. The listener accepts TLS only under ALPN `cmux/tui/1`. The authenticated initiator EndpointID comes from the completed iroh connection.
2. Before opening the cmux-tui Unix socket or forwarding an application byte, it reads one admission frame with a 16 KiB limit and a five-second timeout.
3. Before broker traffic, it verifies the compact JWS with the last authenticated discovery key set, including type `cmux-pair-grant+jwt`, `alg=EdDSA`, TUI ALPN, TUI scope, canonical UUIDs, valid times, and the broker lifetime bound.
4. That local preflight requires the grant initiator EndpointID to equal the TLS initiator EndpointID and the acceptor tuple to equal the persisted local binding. Invalid or cross-endpoint traffic therefore cannot induce authenticated HTTP.
5. It then obtains a current authenticated discovery snapshot. A mutex serializes discovery with relay-fleet replacement, but no prior snapshot can authorize a new connection.
6. It re-verifies the signature with that snapshot's key set and requires every initiator and acceptor field to match exactly one corresponding discovery binding. The acceptor must remain pairable, advertise `cmux.tui.attach`, use route contract 1, and the discovery relay fleet must equal the installed signed relay fleet.
7. Only after all checks pass does it connect to the local session socket, acknowledge admission, and start the byte bridge.

The server revalidates the exact bindings, pairing flag, route contract, and relay fleet at most 30 seconds after the snapshot fetch, including while idle. The first deadline is inherited from the admission snapshot instead of starting a second 30-second window. Stage 1 fails closed on every authentication, HTTP, timeout, decode, contract, fleet, missing-row, or ambiguous-row failure. An independent deadline closes exactly at grant expiry. This is stricter than the accepted policy that permits an already admitted connection to survive a pure broker connectivity failure.

Admission rejection is sticky for that connection. Retrying requires a new TLS connection and a fresh transport admission frame.

## Persistent state

For a state root `<root>` and identity name `<name>`, the sidecar uses `<root>/iroh-tui/<name>/`:

| File | Contents | Mode |
| --- | --- | --- |
| `endpoint.key` | Raw 32-byte Ed25519 seed used by iroh and registration signatures | `0600` |
| `identity.json` | Schema version, device ID, app instance ID, tag, generation | `0600` |
| `credential.json` | Access token and refresh token returned by enrollment | `0600` |
| `relay-policy.json` | Last verified policy sequence, JTI, expiry, and compact JWS | `0600` |
| `state.lock` | Exclusive process lock for this endpoint identity | `0600` |

The directory is opened component by component with `O_NOFOLLOW` through cmux-remote's secure-directory code and ends at mode `0700`. Secret files are read from one descriptor with `O_NOFOLLOW`, owner checks, regular-file checks, byte limits, and no group or other permissions. JSON replacement uses an owner-only temporary file, file sync, atomic rename, and parent sync. Secrets are redacted from `Debug`, errors, logs, scripts, and evidence.

Losing `endpoint.key` means creating a new device identity and binding. Stage 1 never accepts a replacement key for an existing generation and does not implement endpoint rotation proof.

## Relay policy and credentials

The relay-policy verifier implements the accepted v1 schema:

- compact JWS with exactly three segments, `alg=EdDSA`, type `cmux-relay-policy-v1+jwt`, and a pinned key ID;
- claims `version`, `jti`, `sequence`, `iat`, `nbf`, `exp`, `aud`, `relay_protocol`, and `relays`, with unknown fields rejected;
- audience `cmux-iroh-relay-policy`, relay protocol `iroh-relay-v1`, canonical UUID JTI, positive monotonic sequence, a maximum seven-day lifetime, and a 30-second clock skew;
- one to sixteen unique relays, safe identifiers, and canonical root `https://` URLs without user info, ports, paths, queries, or fragments;
- no sequence rollback relative to the cached accepted policy;
- one URL-bound managed credential for every policy relay, with sane refresh and expiry fields.

The production and staging trust roots are compiled from the existing Xcode relay-policy pin configuration. Runtime selects one named environment and cannot add keys or relay URLs through environment variables or flags. Tests can inject keys only through Rust test constructors.

Every endpoint is built with `RelayMode::Custom` from that exact verified set. `RelayMode::Default`, `presets::N0`, public n0 DNS, custom relay flags, and unverified registry hints are absent from the Stage 1 code path.

The relay credential coordinator refreshes before `refresh_after`. It validates the complete replacement policy, credential set, and discovery fleet, inserts or replaces those relay configurations on the live Minimal relay-only endpoint, waits for a verified fleet relay to be connected, commits the new runtime generation, then removes retired relays. The EndpointID and application streams do not change. Failed installation rolls relay configurations back, retries with bounded backoff, and stops accepting new streams before the last installed authorization expires.

## Relationship to cmux-remote

`crates/cmux-remote` already owns hardened process and iroh transport primitives. Stage 1 reuses and slightly generalizes those primitives instead of making a second security implementation:

- endpoint keys use `provider::load_or_create_iroh_secret`;
- state directories use `secure_directory::ensure_secure_directory` and its symlink-resistant traversal;
- credential and metadata reads use `secret_file::read_owner_only`;
- atomic owner-only JSON persistence is extracted from cmux-remote identity storage as a public state-file helper, then used by both identity systems;
- Minimal endpoint construction and authenticated remote-ID checks are extracted from the current iroh provider into public helpers that require an explicit relay mode and path mode;
- the listener uses the same bounded connection, overflow, pending-stream, per-connection stream, and pre-auth admission machinery as `IrohListener`.

The cmux-remote Noise identity and `dev.cmux.remote/1` protocol are not placed on this stream. They authorize a different remote-daemon protocol and local enrollment database. TUI admission is instead the broker-signed same-account pair grant bound to iroh TLS identities, and the payload after admission must remain cmux-tui protocol v10. The existing cmux-remote daemon remains available for its authenticated lane protocol; this Stage 1 sidecar only shares its hardened lower-level machinery.

## Architecture constraint map

| Accepted architecture constraint | Stage 1 implementation choice |
| --- | --- |
| EndpointID is the cryptographic endpoint identity | Persist one Ed25519 iroh secret and compare every dialed or accepted TLS peer with the expected EndpointID. Canonical wire form is lowercase 64-character hex. |
| Reachability hints are never account or grant authority | Bindings select a candidate machine only. Pair-grant claims plus fresh same-account discovery authorize access. Registry path hints are ignored for Stage 1 dialing. |
| One endpoint per transport process | Server and provider each bind one endpoint per process and reject a second process through the identity lock. |
| Minimal preset, verified relays, no n0 defaults | Use `presets::Minimal`, `RelayMode::Custom`, pinned policy verification, and `clear_ip_transports()`. No default discovery or relay mode exists in this path. |
| Publish only safe reachability | Registration publishes no path hints or direct ports. The broker therefore publishes EndpointID only. |
| Globally useful bootstrap | Every peer constructs the remote address from EndpointID plus the complete verified managed relay catalog. No inbound port or local candidate is needed. |
| Private candidates wait behind admission | Stage 1 has no IP transport and therefore no private candidate. Direct and hole-punched paths remain disabled until the fork barrier is available. |
| Grant binds both devices, endpoints, generations, ALPN, scope, time, and JTI | Verify every claim exactly, including TLS initiator and persisted local acceptor identity, under `cmux/tui/1` and `cmux.tui.attach`. |
| Online same-account validation is fail closed | Fetch complete authenticated discovery during admission and every 30 seconds. Missing, duplicate, mismatched, stale, malformed, or unreachable broker state closes the stream. |
| Offline acceptance is tightly limited | Stage 1 has no offline grant or cached-discovery admission path. |
| Grant refresh and expiry are bounded | Provider obtains a grant for each `open_machine`; server closes at its signed expiry. |
| Tokens never cross iroh | Enrollment, Stack credentials, relay credentials, and provider bearer/ticket stay on HTTPS or owner-only local sockets. Only the signed pair grant crosses the admission stream. |
| First application stream is admission-only | The first bounded frame is the pair grant. The local session socket is unopened until admission succeeds. |
| Invalid peers cannot amplify broker traffic | Verify the signed grant, TLS initiator, and exact local acceptor against the last authenticated key set before discovery. Each surviving TLS connection gets one bounded authenticated discovery request under the fixed admission limits. |
| Fixed unauthenticated resource limits | Reuse cmux-remote's bounded semaphores, five-second admission timeout, one admitted protocol stream per connection, and bounded frame sizes. |
| Registration proves endpoint-key possession | Use the exact challenge hash and `cmux/iroh/device-registration/v1` transcript, signed by the persisted endpoint key. |
| Registration slots and rotation semantics | Persist client-minted device ID and tag. Reboot updates the same `(userId, deviceId, tag)` slot. Key loss creates a new identity; rotation is not guessed. |
| Secure platform storage | Use cmux-remote owner-only, `O_NOFOLLOW`, atomic persistence under the cmux-tui state root. |
| Signed relay policy and safe rollout | Verify pins, schema, time, monotonic sequence, exact fleet, and exact credentials before live add-before-remove replacement. EndpointID and application streams stay unchanged. |
| Endpoint-bound relay credential | Fetch credentials only after registration and require the broker-returned EndpointID to match the local endpoint. |
| Custom relays need saved broker metadata | Stage 1 does not support custom relays. |
| No public development relay in production | There is no default or development relay fallback. Startup fails when signed managed policy or credentials are unavailable. |
| Stream credit and backpressure barrier | Before admission, only one bounded admission frame is read. After admission, Tokio copy backpressure and QUIC flow control govern the unchanged byte stream. |
| Redacted diagnostics | Full EndpointIDs, grants, enrollment tokens, session tokens, and relay credentials never enter normal logs. Endpoint labels use a short prefix only. |
| Exact public direct-hint classification | Stage 1 publishes and consumes no direct hints. |
| Platform lifecycle and background behavior | Server is a foreground or supervised headless process. Mobile background lifecycle is outside this Linux/Mac Stage 1. |
| Rollout gates | Feature is opt-in through a separate binary and state directory. Existing remote and local transports are unchanged. |

## Limits and timeouts

| Resource | Limit |
| --- | --- |
| Simultaneous TLS connections | 64 admitted plus 8 bounded overflow waiters |
| Pending streams globally | 64 admitted plus 8 bounded overflow waiters |
| Pending streams per connection | 8, while Stage 1 accepts only the first protocol stream |
| TLS or first-stream wait | 10 seconds and 15 seconds, inherited from cmux-remote |
| Admission frame | 16 KiB, one JSON line, 5 seconds |
| Broker request | 10 seconds, response body 1 MiB maximum |
| Machine-provider control frame | 1 MiB |
| Machine-provider transport handshake | 64 KiB, then streaming bytes without buffering the session |
| Provider ticket | 30 seconds, one use |
| Admission snapshot age | Fetched for the current connection; revalidated within 30 seconds |
| Grant lifetime | Broker maximum seven days, connection closes at signed expiry |

## Verification plan

Unit and integration coverage will prove:

- first boot persists one endpoint key, device ID, app instance ID, and tag; a second boot keeps every value;
- insecure directory, symlink, wrong owner, permissive mode, truncated secret, and oversized state files fail closed;
- registration signs the exact challenge transcript and a repeated registration preserves the broker slot;
- relay policies reject an unknown key, wrong type or audience, non-root URL, duplicate fleet member, expiry, excessive lifetime, and sequence rollback;
- relay credentials must cover the policy fleet exactly;
- grants reject a wrong TLS initiator, wrong local acceptor, mobile ALPN or scope, stale generation, expired time, missing binding, disabled pairing, fleet mismatch, or broker failure;
- no local session byte is read or written before admission success;
- machine-provider hello, snapshot, open, transport handshake, ticket replay, ticket expiry, close, and control-generation replacement follow v1;
- a protocol v10 request and asynchronous event cross the admitted stream byte-for-byte;
- detach closes only the transport, reattach creates a new grant and stream, and the headless session remains alive.

The Docker acceptance script will:

1. build only `cmux-tui` and `cmux-tui-iroh` in one reusable target directory;
2. start a Linux container with no published port and a named identity/state volume;
3. exchange a one-use server provisioning token, launch a headless cmux-tui session, and launch the iroh server sidecar;
4. enroll and start the Mac provider, resolve the container from broker discovery, and attach through its EndpointID and verified relays;
5. create durable session output, detach, reattach, and confirm the same session state;
6. restart the container, confirm the same EndpointID, device ID, tag, and binding ID, then attach again;
7. record timestamps, redacted identity prefixes, broker binding IDs, transport path `relay`, protocol checks, and Docker port mappings in an evidence transcript and terminal recording;
8. remove the exact demo container, volume, image, and temporary host Rust target while retaining the source evidence. It does not globally prune shared Docker caches owned by concurrent work.

Acceptance is complete only when the evidence shows zero published container ports, a catalog-relay path, EndpointID-only remote construction, successful detach and reattach, stable identity across restart, and no credential or full EndpointID disclosure.

## Deferred work

- Direct UDP and NAT hole punching wait for the accepted pre-admission candidate and stream-credit barrier in the cmux iroh fork.
- Offline same-account admission is not implemented.
- Endpoint-key rotation and recovery are not implemented.
- Mobile background lifecycle and constrained-path behavior are not part of this Linux/Mac stage.
- Custom account relays are not implemented.
- Stage 1 uses stricter fail-closed revalidation during broker outages. A later stage may preserve an already admitted connection for classified connectivity failures while keeping policy denial sticky.
