# Transport v2 (CmuxPeerTransport) design

A from-scratch phone↔Mac transport over iroh, replacing the flaky legacy
`CmuxIrohTransport` connection layer. Written against the failure data from the
legacy stack: 35/57 reconnect failures were "superseded by a newer attempt",
207/286 endpoint-unavailable dial failures happened while already connected,
launch-to-ready p50 was 12.7s / p90 105s, and supersession could lock a device
out for ~85s. Every one of those is a connection-management bug above iroh, so
v2 rebuilds that layer with a strict contract and leaves the application lanes
(RPC, terminal, events, artifacts) untouched, riding v2 through thin adapters.

## Acceptance gate

15 continuous minutes of engaged use (typing, streamed output, workspace
switches) in iroh mode with relay-carried traffic:

1. Zero reconnections without an attributed, expected cause (credential expiry
   with make-before-break rotation is not a reconnection; deliberate
   backgrounding is expected).
2. Any reconnection completes in ≤3s from detection to ready.
3. Zero disconnects (no session ends without an attributed cause).
4. Initial connection ≤3s from app open to ready.
5. Every transition, dial, credential event, lane open/close, and error is in
   the structured event log with a reason code — nothing unexplained.

## Package layout

`Packages/Shared/CmuxPeerTransport` with two products:

- **CmuxPeerTransport** (core, no cmux app dependencies): substrate protocols,
  iroh endpoint wrapper, wire framing, admission, reconnect owner, credential
  provider, raw-stream escape hatch, structured event log. Offline-testable.
- **CmuxPeerTransportBridge**: adapters that make v2 raw streams wear the
  legacy stream/transport protocols (`CmxIrohReceiveStream`,
  `CmxIrohSendStream`, `CmxByteTransport`) so the existing lane router and
  `MobileHostService` run unchanged. Depends on `CmuxIrohTransport` for those
  protocol types only.

iroh-ffi pin: `manaflow-ai/iroh-ffi` at the same exact version legacy
`CmuxIrohTransport` pins (one iroh-ffi per SwiftPM graph; the fork artifact
ships make-before-break relay credential handoff, which v2 relies on).

## Wire protocol

- ALPN `cmux/peer-transport/1`, distinct from legacy `cmux/mobile/1` (and the
  parallel experiment `cmux/peer/1`) so all hosts can listen concurrently.
- Frames: 4-byte big-endian length + JSON envelope `{v, t, p}`, 8 MiB cap.
  Unknown `opt.*` frame types are ignored; other unknown types are fatal.
- Control lane: the dialer opens the first bidirectional stream and sends
  `ctl.hello {proto, device_id, app_identity, device_public_key, grant}`.
  Single-phase admission: the host verifies and replies `ctl.admit
  {session_id, relay_credential?}` or closes the connection with a reason
  code. Denials have exactly one channel: the QUIC close reason. No deny
  frame, no sleep-based drain.
- Application lanes: `raw.open {lane, resource_id?, cursor?, offset?}`
  handshake frame, then unframed bytes (the legacy in-lane payload verbatim).
  Bytes the frame decoder over-read past the handshake are re-injected as the
  stream's head. The host opens `server_events` streams toward the phone, so
  both roles run the stream-accept loop.
- Liveness: `ctl.ping`/`ctl.pong` every 15s as a logged liveness assertion and
  latency probe. Reconnect triggers are QUIC events and explicit closes, not
  ping timeouts alone (2 missed pings logs `liveness-degraded` and arms a
  probe dial; it never tears down a working session by itself).

## Admission and grants

`PairingGrant` binds (account, durable device id, device network key, app
identity, grant id, iat/exp) with an Ed25519 signature over a fixed line
transcript. The Mac's `GrantSigner` key and endpoint identity are PERSISTED
(a fresh signer would invalidate every phone's stored grant — a known legacy
trap). Verification order: signature, key match against the QUIC-authenticated
remote key, device/app match, revocation, expiry. Supersession is keyed on
(device id, app identity), replaces immediately, and the superseded close code
is terminal for auto-retry.

## Connection management (the actual fix)

One `ReconnectOwner` actor per Mac peer wraps a pure, total state machine
(idle / connecting / ready / degraded / closed(reason)):

- Automatic triggers JOIN an in-flight attempt; explicit user intent REPLACES
  it. Auto-retry while ready is a no-op. No dial before endpoint-ready.
- Backoff 400ms → 30s cap, doubling on transport failure, reset on success.
  Admission denial is terminal (stale credentials, never transient): drop the
  stored bootstrap, flip routing to legacy for re-credentialing, re-probe.
- Cancelled-but-admitted dials are explicitly closed (phantom-session leak).
- Every exit from ready must carry an injected cause; the transition log is
  the soak's "no sudden reconnects" evidence.
- Lanes are single-consumer. The owner's watch loop is the only control-lane
  consumer and surfaces every host→client frame through an injected handler
  (draining frames to detect death starves credential pushes — legacy bug).

## Relay credentials

Endpoint-bound EdDSA JWTs, 300s TTL, minted from the broker
(`/api/devices/iroh/challenge` → Ed25519 proof → register with
endpoint_already_bound tolerance → `/api/relay/token`). Both sides self-mint:

- Pre-dial: cached credential used if unexpired (offline JWT introspection for
  endpoint_id + exp — a wrong-key token is refused silently by the relay, so
  it is checked before dialing, never after).
- Refresh loop at ~240s plus iOS foreground-wake refresh.
- Rotation is `insertRelay` ALONE (make-before-break in the fork). Never
  removeRelay on a live relay — it severs every session riding it.
- The host also queues the freshest phone credential and delivers it in
  `ctl.admit` on every admission (admission is the only moment the control
  lane is provably alive) plus a best-effort `opt.relay-credential` live push.
- Mint failure never blocks a LAN/direct dial; the endpoint boots LAN-only and
  heals when the broker returns.

## Fast initial connection (≤3s budget)

Persisted per-Mac bootstrap (ticket + grant + identity) loads synchronously at
composition time; the endpoint boots with the cached relay credential (no
network on the critical path); the dial starts on endpoint-ready. Lab-measured
relay dial→admitted is ~0.4s, so the cold-cached path is endpoint boot +
dial ≈ well under 2s. First-ever pairing (no stored bootstrap) is the pairing
flow, not initial connect: a probe over the live authenticated legacy RPC
client calls the Mac's `mobile.transport_v2.pair` RPC once per Mac per run and
persists `{ticket, grant}`.

## Mac host integration

`MobileHostTransportV2Runtime` (DEBUG-gated, defaults-keyed kill switch,
default ON in dev builds): persisted identity + signer, broker credential
client, relay-enabled endpoint, accept loop. Each admitted connection gets a
bridge: synthesized admitted-peer authorization (binding `v2:<grantID>`),
role-aware lane acceptor (a peer-opened server_events stream is a protocol
violation → stream reset), `MobileHostService.acceptTransport` over the
bridged control stream, the existing application lane router through a small
routable-session seam, the existing server-event writer over v2 raw streams,
and the existing admitted-connection supervisor. Socket verbs for diagnostics
(`transport-v2-status`, ticket mint) for the soak harness.

## iOS integration

A facade at the three composition entry points (control transport, bidi lane
open, server event stream): sticky per-Mac routing decided only by probe
verdicts (never dial outcomes), fail-hard while a v2 session reconnects (no
silent legacy fallback — silent fallback is how flakiness hides), kill-switch
defaults key. Soak/dev key forces relay-only dialing by stripping direct
addresses from the dial plan, which is also how the simulator (normally
loopback-routed) exercises the full relay path.

## Structured event log (the verification substrate)

`PeerTransportEventLog`: every event is `{ts, seq, kind, peer, session,
reason?, ms?, detail}` — state transitions, dial start/admitted with
durations, credential minted/rotated/expiring/expired, lane opened/closed,
liveness probes, every error. Sinks: os.Logger at notice (persists in the
unified log) and a JSON-lines file in the app container
(`transport-v2-events.jsonl`) that the soak harness tails. The soak verdict is
computed from this file: any `session-end` or `dial-start` without an expected
attributed cause fails the run; reconnect duration is measured from the
detection event to the next `ready`.

## Soak harness

`scripts/transport-v2-soak.py` (in-worktree): tagged Mac + tagged iOS build on
an isolated per-tag simulator, agent auth profile, relay-only + v2 routing
forced, then 15 minutes of engagement — typed commands into the terminal every
~20s, a streaming-output burst each minute, workspace switches every ~2min —
while tailing both event files. Verdict per the acceptance gate, with every
event classified expected/unexpected. Iterate fix → rebuild → rerun until
pass.
