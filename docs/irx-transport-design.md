# irx transport: a from-scratch iroh transport for cmux mobile

Status: implementation design, branch `feat-irx-transport`, tag `irx`.
Goal: kill the field-measured flakiness of the mobile iroh path (failed initial
connections, spurious reconnections, slow recoveries, relay-boundary drops) by
rebuilding the transport layer end to end, then proving it with a 15-minute
engaged relay-only soak: initial connect <= 3s, zero unexpected reconnects, any
legitimate reconnect <= 3s, zero disconnects.

## Why a rebuild, not another patch

The current stack's failure modes are structural, not incidental:

1. Relay credentials live 300s and refresh only ~60s before expiry, with up to
   30s of early jitter. The relay fleet closes authenticated connections at the
   credential's signed expiry. A missed refresh window (iOS suspension, Mac
   refresh lag, one slow broker call) severs the session.
2. Foreground recovery is serial: await in-flight refresh -> engine resume ->
   discovery refresh -> relay refresh, before a dial is dependable. Any broker
   slowness directly delays reconnect.
3. Admission requires an ONLINE discovery round; only an exact connectivity
   error falls back to offline grant verification. Broker RTT and hiccups sit
   on the connect path.
4. No transport keepalive: dead connections surface only via a 3s liveness
   probe after render silence, a QUIC idle timeout, or a failed write.
5. Multiple reconnect ladders compound (app recovery owner 2..60s, client
   runtime 1..30s, endpoint supervisor, Mac host rebuild 30s..1h).
6. Every connectivity route-revision push invalidates all pooled peer
   sessions, forcing full re-dials of healthy connections.

## What is rebuilt vs consumed

Rebuilt from scratch (package `Packages/Shared/CmuxIrxTransport`, prefix
`Irx`, wire ALPN `cmux/irx/1`):
- identity, endpoint lifecycle, relay credential management, broker client,
  registration, grant verification, dial/admission, session + lane protocol,
  reconnect ownership, keepalive, supersession, event journaling.

Consumed unchanged (stable, not flaky, and battle-tested):
- iroh-ffi fork binary `1.0.2-cmux.7`, the CI-built main-line artifact
  (pinned iroh fork rev 4152d81, which ships make-before-break relay
  credential handoff). Note: the `cmux.8` tag is unusable as a pin because its
  release asset was re-uploaded after the manifest checksum was baked; the
  upstream-binary consumption trap it fixed applied only to the cmux-lite
  branch manifest, never to this main line.
- Web backend: `/api/devices/iroh/{challenge,register}`, `GET /api/devices/iroh`
  (discover), `/api/devices/iroh/pair-grants`, `/api/relay/token`. No server
  changes; steady state needs only a valid relay token.
- App-level payload contracts: `MobileSyncFrameCodec` RPC frames,
  `CmxIrohTerminalOutputEnvelope` terminal framing, 16 KiB input frames,
  `MobileHostService.acceptTransport`, `MobileTerminalByteTee` replay,
  `CmxByteTransport`/lane provider seams on iOS.

## Activation model

Defaults key `cmux.irx.enabled` (DEBUG builds; Debug menu + env
`CMUX_IRX_ENABLED=1` for launches). When ON:
- the legacy iroh runtimes (Mac `MobileHostIrohRuntime` activation, iOS
  `MobileIrohRuntimeComposition` start) are NOT activated; the irx runtime owns
  the app's iroh identity slot (registration under the build's tag), route
  publication, pairing, and all mobile traffic.
- When OFF (default, and always in Release), nothing changes; irx code is
  dormant. Release builds compile the package but cannot enable it.

This avoids binding-slot reincarnation wars: the broker keys binding slots by
(user, device, tag); running two runtimes with two endpoint keys under one slot
would revoke each other in a loop. One runtime owns the slot per build.

Grant note: pair grants are minted by the existing broker with claim
`alpn: cmux/mobile/1`. irx treats that claim as the pairing-scope identifier
(the authority the server signed), not the wire protocol; the wire ALPN is
`cmux/irx/1` so legacy peers can never half-connect to an irx endpoint.

## Layered design (contract-informed)

State machine (per Mac peer, five states, single owner):
idle -> connecting -> ready -> degraded -> closed(reason); no parallel shadow
state. Every close carries an attributed reason; the reason travels in the QUIC
CONNECTION_CLOSE payload (single channel, no deny/close frames, no sleeps).

### L0 identity
One Ed25519 keypair per (device, app identity), Keychain in Release, dev file
store in DEBUG (mirrors legacy repo layout). Public key = iroh EndpointId.

### L1 endpoint + relay credentials
- `IrxEndpointSupervisor` (actor): binds one endpoint per process generation
  with `RelayMode.custom` built from the credential store; reports `ready`
  before anyone may dial; recreates on unexpected close; health-check +
  rebind after suspension resume.
- `IrxRelayCredentialCoordinator`: mints via `POST /api/relay/token` (Stack
  bearer from the app's auth), persists credentials + policy, refreshes at
  `min(refreshAfter, exp - 120s)` with <= 10s jitter; on failure retries at
  half the remaining validity, floor 1s; post-expiry retry 1s. Rotation is
  `insertRelay` ALONE with the fresh token (fork make-before-break
  authenticates a replacement connection before swapping; never removeRelay
  for a URL being rotated - remove severs relay-carried sessions instantly).
  Foreground resume triggers an immediate staleness check, but a fresh cached
  credential means ZERO broker calls on the connect path.
- Relay-only forcing (`cmux.irx.force-relay` / `CMUX_IRX_FORCE_RELAY=1`):
  dial addresses carry relayUrl only (no direct candidates) and NAT traversal
  is never authorized (endpoint binds with deferred NAT traversal), so every
  byte stays on the relay. Used by the soak; also a user-visible reliability
  mode later.

### L2 admission
- Client hello (first frames on the control stream): protocol id, device id,
  app identity/build scope, endpoint key, pair-grant JWS (+ fresh grant on
  renewal). One round trip: `admit{session}` or reasoned termination.
- `IrxGrantVerifier`: verifies the broker's Ed25519 JWS OFFLINE against
  `grant_verification_keys` pinned from the last authenticated discovery
  (cached on disk, refreshed opportunistically in the background, never on
  the admission path). Enforces: signature, time window (30s tolerance),
  initiator tuple (endpointId == TLS-authenticated key, platform ios),
  acceptor tuple (this Mac's binding), revocation cache. NO online round at
  admission time - revocations arrive via connectivity invalidations and are
  enforced at the next admission (contract 9.3/9.5 steady-state independence).
- Supersession: a new admitted connection from the same device identity
  replaces the old session immediately (close reason `superseded`); a dead
  process never blocks re-admission.

### L3 session + reconnect
- `IrxPeerEngine` (actor, one per Mac peer, iOS side): THE single dialer.
  Triggers (app recovery owner, foreground, network path change, keepalive
  death, explicit retry) are inputs; automatic triggers join the in-flight
  attempt, explicit intent replaces it. Backoff: 0.4s floor, x2, 5s cap while
  a network path exists (target: any recovery <= 3s), 30s cap without one;
  reset on success. Denials are terminal for automatic retry.
- Keepalive: control-lane ping every 10s of send/receive silence, pong
  deadline 3s; a miss closes with `keepalive-timeout` and triggers an
  immediate redial (first attempt has no backoff). Any traffic counts as
  liveness, so an engaged session never pings.
- Route revisions reconcile stored routes but NEVER invalidate a healthy
  admitted session.

### L4 lanes
Lanes map 1:1 onto QUIC bidirectional streams; no cross-lane blocking, per-lane
backpressure via QUIC flow control. Stream open protocol: one length-prefixed
JSON descriptor `{lane, resource?, cursor?, offset?}` then RAW bytes (no
base64 bulk overhead; the app payload contracts are already binary framed).
Lane kinds: `control` (MobileSyncFrameCodec RPC frames), `events` (server ->
client event frames), `terminal` (envelope replay+chunks down, length-prefixed
input up), `artifact` (offset read stream). Send priorities: events 50,
control 20, terminal 0, artifact -10.

### Observability (contractual)
`IrxJournal`: every state transition, dial attempt (with per-path outcome and
timing), admission, denial, credential mint/rotation (with expiry timestamps),
keepalive ping/pong, lane open/close, and close reason is written as one JSONL
event (monotonic + wall timestamps) to an app-container journal file (DEBUG)
AND mirrored to os.Logger notice level (subsystem `dev.cmux` category
`irx-host`, subsystem `dev.cmux.ios` category `irx-client`) so `log show`
persists it. The soak analyzer consumes both sides' journals; "connection lost
with no attributed cause" is a contract bug, not a logging gap.

## Mac integration
`Sources/Mobile/MobileHostIrxRuntime.swift`: activation gated as above;
identity -> registration (pairingEnabled, direct ports, relay path hints) ->
endpoint bind -> accept loop -> admission -> per-connection:
- control lane wrapped as `CmxByteTransport` -> `MobileHostService
  .acceptTransport(..., authorization: .irohAdmission(peer))` (RPC, ordered
  per-surface queues, supersession registry - all reused);
- `events` lane handed to an `MobileHostIndependentEventWriting` adapter;
- terminal lanes served from `MobileTerminalByteTee` replay state with
  `CmxIrohTerminalOutputEnvelope` framing (cursor-gap -> error close code);
- artifact lanes via the existing artifact registry.
Route publication feeds the same ticket/registry path the legacy runtime used
(`updateIrohRoute`-equivalent) so attach tickets and presence advertise the
irx endpoint. Diagnostics: v1 socket verb `irx_diag` (journal tail + counters,
nonisolated ring like `iroh_diag`).

## iOS integration
`MobileIrxRuntimeComposition`: when enabled, cmuxApp registers ONLY the irx
transport factory for `.iroh` routes (no debug-loopback/tailscale fallbacks in
irx mode, so a simulator exercises the real iroh path), and wires
`independentEventByteStreamProvider`, `terminalLaneProvider`,
`artifactLaneProvider` to irx lanes. The app-level recovery owner keeps its
role as trigger source; `IrxPeerEngine` guarantees single-flight dialing
underneath and surfaces closures through `CmxByteTransportClosureObserving` so
the app reacts immediately instead of waiting for probes.

## Soak verification (the acceptance gate)
Isolated simulator + tagged Mac (`irx`), relay-only forced on both ends,
15 continuous minutes of engaged use (terminal I/O driven the whole time,
crossing >= 3 relay-token boundaries):
1. initial open -> ready <= 3s (journal-timed);
2. zero session closes except deliberately injected ones;
3. every reconnect (only if injected/expected) ready again <= 3s;
4. zero credential expiry events; >= 3 zero-gap rotations observed on each
   side; relay path attribution holds for the whole session;
5. every journal event classified; any unexplained transition = FAIL.
Analyzer: `scripts/irx-soak.py` (drives input, samples journals, prints a
verdict with evidence files).
