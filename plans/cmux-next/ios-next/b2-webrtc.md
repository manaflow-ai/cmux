# B2 `webrtc`: the WebRTC carrier (V1)

Status: landed (local) on `feat-cmux-next-ios-b2-webrtc`, 2026-10-06. Plan: [PLAN.md](PLAN.md) section 2, B2.
Binding: [a3-link.md](a3-link.md) (carrier contract, conformance), [a0-rpc.md](a0-rpc.md) section 3.1
(message carriers send one record per message, no length prefix) and 5.12 (`signal`),
[b1-control-do.md](b1-control-do.md) sections 5, 6, 10 (relay, TURN minting, `ControlPlaneClient`),
[b4-direct.md](b4-direct.md) (sibling carrier, key pinning), `transport.md`, `OWNERSHIP-PRINCIPLES.md`.
Code: `Packages/Shared/CmuxLinkWebRTC` (Swift 6, iOS 17, macOS 14; targets `CmuxLinkWebRTC` and
`CmuxLinkWebRTCUnderlay`), the shared signaling seam `CmuxLinkSignaling` in `Packages/Shared/CmuxLink`.

## 1. What it is

`WebRTCCarrier` (dialer, the phone) and `WebRTCAcceptor` (host, the Mac app process, wired by B5)
implement A3's `LinkCarrier` and `LinkAcceptor`. A transport is one `RTCPeerConnection`: data
channels carry `LinkFrame`s, media tracks carry browser and VNC video. Signaling (SDP and trickle
ICE) rides the control plane through `HostDO`; ICE servers come from B1's Cloudflare Realtime TURN
minting. Everything above lanes (channels, revisions, resume, credit, priority) stays in
`LinkSession`/`LinkHost`. A transport reports `LinkPath(kind: .p2p | .turn, carrier: .webrtc)`.

## 2. Stack choice: Google libwebrtc, prebuilt xcframework, SwiftPM binary target

The repo vendors no WebRTC today (no package, pod, xcframework or Rust crate references it). Options:

| | libwebrtc xcframework (stasel/WebRTC M154) | libdatachannel (+ separate media path) |
| --- | --- | --- |
| Data channels | yes (dcSCTP, DCEP, partial reliability) | yes (usrsctp) |
| Media tracks | yes: VideoToolbox H.264/HEVC, VP8/VP9/AV1, jitter buffer, GCC congestion control, simulcast, `RTCMTLVideoView` | RTP packetization only: we would build jitter buffer, congestion control, decoder and renderer pipeline ourselves |
| Browser interop | reference implementation | good for data, partial for media |
| Integration | `.binaryTarget(url:checksum:)`, one line, iOS + simulator + macOS + Catalyst slices | CMake + OpenSSL or mbedTLS cross-builds per platform, our own xcframework and CI job |
| Size | zip 45 MB; iOS arm64 slice 12 MB (dynamic framework, about 5 MB compressed in the IPA); macOS universal 28 MB | about 2 to 3 MB data-only, plus whatever media stack we write |
| Maintenance | republished per Chrome milestone; we bump URL + checksum | we own the build forever |

Decision: libwebrtc via `stasel/WebRTC` M154 as a SwiftPM `binaryTarget` pinned by URL and checksum
(no git dependency on the publisher's repo). C2 (browser stream) and C3 (VNC) need real video with
hardware decode and congestion control; libdatachannel would make us write a media engine to save
about 7 MB compressed. The same framework serves the Mac side (B5 embeds `WebRTCAcceptor` in the app
process, as a3-link.md section 10 allows). Follow-ups: mirror the zip to `files.cmux.com/webrtc/M154/`
and point the URL there so a deleted GitHub release cannot break builds; ship dSYMs (416 MB, separate
asset) only to Sentry, never into the repo. A Rust host (cmux-tui) never links this; if the session
host moves to Rust, it uses `webrtc-rs` or libdatachannel against the same wire (sections 4 to 6).

## 3. Ownership

| Fact | Owner | Others |
| --- | --- | --- |
| The peer connection, its data channels and tracks | the transport (one per connect) | session sees lanes only |
| Which signaling session a message belongs to | `SignalRouter` (one per signaling channel) | the relay only forwards |
| ICE servers and TURN credentials | the backend (B1 mints, 900 s TTL) | carrier caches until `expires_at - 60 s` |
| Device and host identity keys (P-256, Secure Enclave when available) | each install (B6 provisions) | the peer pins the public key |
| Which device keys may connect | the host's trust store via `WebRTCAuthorizer` (B5 plugs B6) | carrier holds no list |
| Which host key a dialer expects | pairing record via `WebRTCHostKeyResolver` (hints `webrtc.hostKey`) | |
| Path classification | the transport, from the selected ICE candidate pair | badge mirrors it |

## 4. Signaling over the control plane

`SignalingChannel` (CmuxLink's `CmuxLinkSignaling` target, shared with B3 so there is one signaling
protocol) is the seam: `send(SignalMessage)` and one inbound `AsyncStream<SignalMessage>`.
`SignalPayload` is typed per kind, so it matches B1's frames (offer `ice_restart`, `carrier`, `auth`;
integer `sdp_mline_index`). Adapters in `CmuxLinkWebRTC`: `ControlPlaneSignaling` over
`ControlPlaneClient` on the phone (`sendSignal`, `signals`, `read signal.turn_credentials`) and
`SignalFrameChannel` for the Mac, whose host socket B5 owns (`receive(_:)` matches B5's
`SignalingSink`; `send` writes `signal` frames). `InMemorySignalingHub` is the test double that
rewrites `from` like `HostDO` and can intercept messages (MITM tests). `SignalRouter` consumes the
inbound stream once and demultiplexes by `session`; an `offer` for an unknown session goes to the
acceptor registered for its `carrier` (`newSessions(for:)`), so V1 and V2 share one host socket.

Flow (the dialer is the only offerer for the data session; perfect negotiation for media below):

1. Dialer: mint `session = sess_<22 base62>`, fetch ICE servers, create the peer connection and the
   `cmux/1 ctl` data channel (so the offer has an `m=application`), create and sign the offer, send
   `offer {sdp, carrier: "webrtc", ice_restart: false, auth}` to `peer.hints["webrtc.to"] ?? hostID`.
2. Both: trickle `ice {candidate, sdp_mid, sdp_mline_index}` as gathered, `ice.end` at completion.
   Candidates that arrive before the remote description are buffered, then applied in order.
3. Host: verify `auth` (section 8), set the offer, answer, sign, send `answer {sdp, auth}`.
4. Dialer: verify the answer's `auth` against the pinned host key, set it.
5. The transport is live when the `ctl` channel is open (ICE, DTLS and SCTP are up and the peer
   proved its key). `connect` returns it; the acceptor yields it on `incoming`.
6. `bye {reason}` on close or failure; a `bye` from the peer ends the transport (`pathLost`) unless a
   graceful close already ran.

Rate: `HostDO` allows 120 signal frames per 10 s per socket. One connect costs 1 offer, 1 answer, one
`ice` per candidate (host, srflx, relay per interface, typically 4 to 10) and 1 `ice.end` per side.

Media renegotiation: the host offers when it adds a track (`peerConnectionShouldNegotiate`). The
dialer is the polite peer (`enableImplicitRollback`): on glare it rolls back its own offer and
answers; the host ignores a colliding dialer offer. Both directions sign every description.

## 5. ICE configuration

`ICEServerProvider.iceConfiguration(for: hostID)` returns `{servers, expiresAt}`. The control-plane
adapter calls `read signal.turn_credentials {host}` on the host socket and decodes
`{ice_servers [{urls, username?, credential?}], expires_at}` (Cloudflare Realtime: `stun:` +
`turn:...?transport=udp|tcp` + `turns:...:5349`). `signal.turn_unavailable` (no secrets, or the
upstream failed) degrades to Cloudflare's credential-free STUN (`stun:stun.cloudflare.com:3478`):
P2P still works, relayed paths do not. The carrier caches the configuration until 60 s before
expiry and refreshes it before an ICE restart (`setConfiguration`).

`RTCConfiguration`: unified plan, `maxBundle`, `rtcpMux require`, ECDSA certificate,
`continualGatheringPolicy gatherContinually` (new interfaces after a roam produce candidates without
a restart), `iceTransportPolicy all`, TCP candidates enabled (TURN over TCP/TLS for UDP-hostile
networks), `iceCandidatePoolSize 0`. Tests use host candidates only, loopback allowed, no servers.

## 6. Lanes on data channels

One data channel per distinct `TransportLane`, created by the side that first sends on it (DCEP,
in-band, so no extra signaling), label `cmux/1 <class> <priority>`:

| Lane | Label class | `RTCDataChannelConfiguration` |
| --- | --- | --- |
| `reliableOrdered` | `r` | `ordered: true` |
| `unreliableUnordered` | `u` | `ordered: false, maxRetransmits: 0` |
| `partial(maxLifetime)` | `p<ms>` | `ordered: false, maxPacketLifeTime: ms` (clamped to 1...65535) |

The receiver maps a channel to its lane from the label. If both sides open the same lane at once there
are two channels with one label; each side sends on the first it registered and reads from both, so
order per lane holds per sender. Messages are the opaque `TransportFrame` bytes, one per message, no
prefix (a0-rpc.md 3.1). `maxFrameBytes` is 256 KiB, the SCTP `max-message-size` libwebrtc offers.
Cross-lane order is not promised; `LinkSession` already sends channel-scoped control on the channel's
reliable lane (a3-link.md section 4), so an `open` never overtakes its data.

`ctl` (reliable, ordered) carries the carrier's own JSON messages: `fin {counts}` / `fin.ack` for
graceful close and `track {id, kind, label}` for media descriptors. It never carries link frames.

Large frames and pacing (d2-bakeoff.md F1): libwebrtc bursts big SCTP messages into the peer's UDP
socket; past its buffer (786 KiB by default on macOS, less in practice because each datagram costs a
2 KiB mbuf) packets drop and dcSCTP's recovery stalls the whole association, so every lane waited
seconds behind bulk. The carrier now:
- splits every lane frame into data channel messages of at most `maxMessageBytes` (8 KiB). Each lane
  message starts with one byte: `0x00` last piece (or whole frame), `0x01` more follow (reliable lanes,
  SCTP keeps order), `0x02` an indexed piece on unordered and partial lanes (`u32 frame id | u16 index |
  u16 count`, delivered only when complete, at most 8 incomplete frames kept per channel). `ctl` and
  `wg` carry no header. One record per frame still holds above the carrier;
- queues pieces per lane and moves them into libwebrtc from one scheduler task, always from the
  highest-priority lane with a piece whose channel is open and has `bufferedAmount` at or below
  `highWaterBytes` (128 KiB). The task sleeps on wake events (a send queued, a channel opened,
  `didChangeBufferedAmount`), never on a timer. A keystroke waits behind at most one 8 KiB piece;
- keeps at most `inFlightWindowBytes` (256 KiB) of reliable lane bytes sent but not credited: the
  receiver sends `credit {received}` (cumulative) on `ctl` every window/8 bytes. Input and control lanes
  and unreliable lanes bypass the window. 256 KiB is 40 Mbit/s at 50 ms RTT; D2's device runs decide
  whether a larger window is safe on phones.
- `send` suspends while its lane holds `laneBudgetBytes` (1 MiB) of queued pieces (reliable) or drops
  the frame (unordered, partial); graceful close waits until the reliable queues are flushed before `fin`.

Graceful close: `close()` sends `fin` with the number of messages it sent on each reliable lane. The
peer emits `.closed(.remote)` only after it received that many on each lane, answers `fin.ack`, and
the closer then closes the peer connection (bounded by `closeTimeout` on the injected clock).

## 7. Path classification and ICE restart

The selected pair is reported by `didChangeLocalCandidate:remoteCandidate:` (libwebrtc's
`OnIceSelectedCandidatePairChanged`), and read once more from `getStats` when ICE reaches
`connected`. `CandidatePairClassifier`: either candidate of type `relay` gives `.turn`; host, srflx
and prflx pairs give `.p2p`. A change of kind on a live transport emits `.pathChanged`, so the badge
moves from p2p to TURN without a reconnect.

ICE restart (dialer drives, host follows):
- ICE `failed` restarts at once; `disconnected` restarts after `disconnectedGrace` (2 s, injected
  clock, cancelled when ICE recovers by itself).
- `WebRTCCarrier.networkDidChange()` (fed by the app's NWPathMonitor, next to
  `LinkSession.networkDidChange()`) restarts ICE on every live dialer transport at once.
- Restart: refresh ICE servers, `setConfiguration`, `restartIce`, offer with `ice_restart: true`.
  No `connected` within `iceRestartTimeout` (10 s) closes the transport with `pathLost`, and the
  session's reconnect races every carrier again. The host waits for the dialer's restart offer
  under the same deadline.

## 8. End-to-end authentication

Neither the relay nor the DO is trusted with the media or data keys. DTLS already binds the media and
data plane to the certificate fingerprint in the SDP; we bind that fingerprint to the install keys:

- Keys: P-256 ECDSA (`SecureEnclave.P256.Signing` on device, `P256.Signing` in software and tests),
  the same install identity B6 signs B4's X25519 keys with. Public keys are X9.63 (65 bytes) base64.
- Statement: `cmux.webrtc/1`, role (`offer` or `answer`), `session`, `hostID`, the signer's DTLS
  fingerprint (`sha-256`, upper hex with colons, every `a=fingerprint` in the SDP must equal it), and
  for an answer also the offer's fingerprint. Joined with `\n`, signed with ECDSA SHA-256.
- Body: `auth {key, sig}` on `offer` and `answer` (new optional field in
  `families/signal.schema.json`; the relay validates the shape, peers require it).
- Host: rejects an offer whose signature fails, whose key `WebRTCAuthorizer` refuses (unpaired
  device), or whose fingerprint does not match; answers `bye {reason: revoked}` and creates nothing.
- Dialer: verifies the answer against the pinned host key from `WebRTCHostKeyResolver` (no key means
  no connect: `WebRTCCarrierError.noHostKey`).

A relay that swaps SDPs cannot sign for the pinned keys; a replayed old offer names a certificate whose
private key died with its peer connection, so DTLS fails. The relay still sees ICE candidates (IP
addresses), which transport.md accepts for the control plane.

## 9. Peer identity and V2 underlay

`LinkTransport.peerIdentity` (CmuxLink, default nil) carries what a carrier authenticated. A
`WebRTCTransport` reports `LinkPeerIdentity(carrier: .webrtc, keyKind: .p256, publicKey: <the key
bound to the peer's DTLS fingerprint>, install: <relay-rewritten from, host side>)`. `LinkSession`
exposes it (`peerIdentity`); on the host it is fixed by the session's first transport, and
`LinkHost` refuses to resume or replace a session from a transport that proved another key of the
same kind. B5 maps it to its `CarrierAttestation` (`install`, `carrier`) when it builds a
`MobileSessionServer`. B4's `DirectTransport` should return
`LinkPeerIdentity(carrier: .direct, keyKind: .x25519, publicKey: remoteKey.rawRepresentation)`
(no install; B5 resolves the key through its trust store).

V2 (B3) rides the same peer connection code in datagram mode: `WebRTCDatagramDialer` and
`WebRTCDatagramListener` open one `wg` channel (`ordered: false, maxRetransmits: 0`), offers tagged
`carrier: webrtc-wg`, no fingerprint binding (WireGuard is the boundary), `close()` sends `bye`.
`CmuxLinkWebRTCUnderlay` adapts them to B3's `DatagramUnderlay`: `bye` maps to `.reset`, a dead path
to `.pathLost`, selected-pair moves to `.pathChanged`.

Threading rule learned the hard way: libwebrtc's ObjC objects proxy calls to its signaling and
network threads and block, and those threads call our delegates. The peer's lock is never held
while calling into libwebrtc (re-check after registering a waiter instead), and the final close and
release of every libwebrtc object run on a private serial queue, never on the cooperative pool.

## 10. API

```swift
// CmuxLinkSignaling
public protocol SignalingChannel: Sendable {
    func send(_ message: SignalMessage) async throws
    var incoming: AsyncStream<SignalMessage> { get }
}
public actor SignalRouter { init(channel:); func register(_ session:) -> AsyncStream<SignalMessage>; func newSessions(for: CarrierKind) -> AsyncStream<Incoming> }
public final class InMemorySignalingHub { func endpoint(id:) -> SignalingChannel; func setInterceptor(_:) }
// CmuxLinkWebRTC
public protocol ICEServerProvider: Sendable { func iceConfiguration(for hostID: String) async throws -> ICEConfiguration }
public final class ControlPlaneSignaling: SignalingChannel, ICEServerProvider { init(client: ControlPlaneClient) }
public final class SignalFrameChannel: SignalingChannel { init(send: (SignalFrame) async throws -> Void); func receive(_: SignalFrame) async }
public protocol WebRTCIdentity: Sendable { var publicKey: WebRTCPublicKey { get }; func sign(_:) throws -> Data }
public struct SoftwareWebRTCIdentity: WebRTCIdentity; public struct SecureEnclaveWebRTCIdentity: WebRTCIdentity
public protocol WebRTCAuthorizer: Sendable { func authorize(device: WebRTCPublicKey, install: String?) async -> Bool }
public protocol WebRTCHostKeyResolver: Sendable { func hostKey(for peer: LinkPeer) async -> WebRTCPublicKey? }
public final class WebRTCCarrier: LinkCarrier {        // kind .webrtc, candidatePaths [.p2p, .turn]
    init(signaling: | router:, iceServers:, identity:, hostKeys: = WebRTCHintsResolver(), configuration: = .init())
    func networkDidChange() async
}
public final class WebRTCAcceptor: LinkAcceptor {
    init(signaling: | router:, iceServers:, identity:, hostID:, authorizer:, configuration: = .init())
    func start() async; func stop() async
}
public final class WebRTCTransport: LinkTransport { let remoteKey: WebRTCPublicKey; let peerIdentity; func restartICE() async }
public final class WebRTCDatagramDialer { func open(to: LinkPeer) async throws -> WebRTCDatagramChannel }
public final class WebRTCDatagramListener { var incoming: AsyncStream<WebRTCDatagramChannel>; func start() async; func stop() }
public struct WebRTCPixelBufferBox / WebRTCVideoFrameBox   // MediaFrame.Payload.native for push / sinks
// CmuxLinkWebRTCUnderlay: WebRTCUnderlay, WebRTCUnderlayDialer, WebRTCUnderlayListener (B3 protocols)
```

## 11. Tests (Swift Testing, `swift test` in the package, no network)

33 tests (7 conformance cases counted once per parameterized test), about 2.5 s, stable over 7 runs:
- `LinkConformanceSuite`, all seven cases passed (none skipped), two in-process libwebrtc peers over
  loopback host candidates with `InMemorySignalingHub`; drop closes the real peer connections,
  path change and roam inject the selected-pair classification (no TURN server in tests), throttle
  paces sends through `WebRTCFaultInjector`.
- B3's `WireGuardConformanceHarness`, all seven cases passed over the real loopback `wg` underlay,
  plus underlay datagrams and `bye` as `.reset`, and one host router feeding V1 and V2 acceptors.
- Signaling: the A0 `signal` fixtures round trip through `SignalFrameCodec`, auth encoding,
  carriers, session id pattern, relay `from` rewrite, router demux, `SignalFrameChannel`.
- ICE: TURN fixture decoding, defensive decoding, cache expiry margin.
- Fingerprint binding: SDP parsing, statement bytes, sign/verify and tamper cases, mutual identity,
  unpaired device (no transport, `bye revoked`), wrong pinned host key, no host key, a relay that
  re-signs the answer, a relay that rewrites the offer's fingerprint.
- Path: candidate types, classifier table, lane labels; transport: loopback is p2p, per-lane order
  with 256 KiB frames, graceful close delivers 300 frames then one `closed(remote)`, drop, ICE
  restart keeps the transport, a host video track renders frames at the dialer, audio refused.

CmuxLink gained `PeerIdentityTests` (identity exposed, other key refused on resume; red without the
`LinkHost` check); its 37 tests and B3's 39 tests pass. The backend `auth` validation test was added
to `host-signal.test.ts` but not run (no `node_modules` on this Mac).

## 12. Live verification (credentials are absent on this machine)

1. Backend: follow [the TURN section in the backend runbook](../backend-runbook.md) to set
   `CLOUDFLARE_TURN_KEY_ID` and `CLOUDFLARE_TURN_KEY_API_TOKEN` on the development environment;
   the secrets-safe probe of `POST /v1/realtime/turn` must return `ice_servers` with `turn:` or
   `turns:` URLs. A successful HTTP mint is necessary but does not prove an ICE relay.
2. Mac (B5) runs `WebRTCAcceptor` on its host socket; phone on cellular dials with `WebRTCCarrier`;
   badge shows `p2p` on the same LAN, `turn` with `iceTransportPolicy relay` forced from the DEV menu.
3. Roam Wi-Fi to cellular mid-terminal: ICE restart keeps the session (`pathChanged`), or the
   session reconnects and resumes with no gap.
4. MITM check: a dev relay build that rewrites SDP fingerprints must fail every connect with
   `auth` errors on both ends.

Wiring for B5 (Mac): `let channel = SignalFrameChannel { try await socket.send(<signal frame JSON>) }`,
`extension SignalFrameChannel: SignalingSink {}` so `HostControlUplink(signaling: channel)` feeds it,
one `SignalRouter(channel:)` shared by `WebRTCAcceptor(router:...)` (passed to `MobileHost`) and,
for V2, `WebRTCDatagramListener(router:...)`; map `LinkSession.peerIdentity` to `CarrierAttestation`.

Open items: a `send` suspended on a full data channel resumes only when the buffer drains or the
transport closes (not on task cancellation); RTT is sampled at connect and on ICE `connected`, not
continuously; audio tracks are refused (voice is a later lane); the binary URL should move to
`files.cmux.com` before release; the host socket's per-socket signal budget (120 per 10 s) bounds
how many simultaneous connects one phone can start.

## 13. Not in this lane

Mac app wiring and the host socket owner (B5), key provisioning and the trust store (B6), browser and
VNC encoders and renderers (C2, C3; this lane gives them track handles), the badge UI (C11, D1),
V1 vs V2 measurements (D2).
