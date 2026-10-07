# B2 `webrtc`: the WebRTC carrier (V1)

Status: design, 2026-10-06, branch `feat-cmux-next-ios-b2-webrtc`. Plan: [PLAN.md](PLAN.md) section 2, B2.
Binding: [a3-link.md](a3-link.md) (carrier contract, conformance), [a0-rpc.md](a0-rpc.md) section 3.1
(message carriers send one record per message, no length prefix) and 5.12 (`signal`),
[b1-control-do.md](b1-control-do.md) sections 5, 6, 10 (relay, TURN minting, `ControlPlaneClient`),
[b4-direct.md](b4-direct.md) (sibling carrier, key pinning), `transport.md`, `OWNERSHIP-PRINCIPLES.md`.
Code: `Packages/Shared/CmuxLinkWebRTC` (Swift 6, iOS 17, macOS 14).

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

`SignalingChannel` is the seam: `send(SignalMessage)` and one inbound `AsyncStream<SignalMessage>`.
`ControlPlaneSignaling` adapts `ControlPlaneClient` (`sendSignal`, `signals`, and
`read signal.turn_credentials`); `InMemorySignalingHub` is the test double that rewrites `from` like
`HostDO` and can intercept messages (MITM tests). `SignalRouter` consumes the inbound stream once and
demultiplexes by `session`; unknown sessions with an `offer` go to the acceptor.

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

Back-pressure: `send` suspends while a channel's `bufferedAmount` is above 1 MiB and resumes from the
`didChangeBufferedAmount` callback once it falls under 256 KiB (no polling). Unreliable lanes do not
wait: above the high-water mark the frame is dropped (media semantics, a3-link.md section 4).

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

## 9. API

```swift
public protocol SignalingChannel: Sendable {
    func send(_ message: SignalMessage) async throws
    var incoming: AsyncStream<SignalMessage> { get }
}
public protocol ICEServerProvider: Sendable { func iceConfiguration(for hostID: String) async throws -> ICEConfiguration }
public final class ControlPlaneSignaling: SignalingChannel, ICEServerProvider { init(client: ControlPlaneClient) }
public final class InMemorySignalingHub { func endpoint(id:) -> SignalingChannel; func setInterceptor(_:) }
public protocol WebRTCIdentity: Sendable { var publicKey: WebRTCPublicKey { get }; func sign(_:) throws -> Data }
public struct SoftwareWebRTCIdentity: WebRTCIdentity; public struct SecureEnclaveWebRTCIdentity: WebRTCIdentity
public protocol WebRTCAuthorizer: Sendable { func authorize(device: WebRTCPublicKey, install: String?) async -> Bool }
public protocol WebRTCHostKeyResolver: Sendable { func hostKey(for peer: LinkPeer) async -> WebRTCPublicKey? }
public final class WebRTCCarrier: LinkCarrier {
    init(signaling:, iceServers:, identity:, hostKeys: = WebRTCHintsResolver(), configuration: = .init())
    func networkDidChange() async
}
public final class WebRTCAcceptor: LinkAcceptor {
    init(signaling:, iceServers:, identity:, hostID:, authorizer:, configuration: = .init())
    func start() async; func stop() async
}
public final class WebRTCTransport: LinkTransport { let remoteKey: WebRTCPublicKey; func restartICE() async }
```

## 10. Tests (Swift Testing, `swift test` in the package, no network)

- `LinkConformanceSuite`, all seven cases, two in-process peers over loopback host candidates with
  `InMemorySignalingHub`; drop, path change, roam and throttle via `@_spi(Testing)
  WebRTCFaultInjector` (drop closes the real peer connections; path change and roam inject the
  classification event the selected-pair callback would produce, since tests have no TURN server).
- Signaling: codec to and from `SignalFrame` per the A0 fixtures, router demux and early-candidate
  buffering, TURN credential decoding and the `turn_unavailable` fallback.
- Fingerprint binding: SDP parsing, statement bytes, tampered SDP, wrong host key, unpaired device,
  swapped auth through an intercepting relay.
- Path classification: candidate lines for host, srflx, prflx, relay pairs.

## 11. Live verification (credentials are absent on this machine)

1. Backend: `wrangler secret put CLOUDFLARE_TURN_KEY_ID` and `CLOUDFLARE_TURN_KEY_API_TOKEN` on a dev
   env; `curl -X POST /v1/realtime/turn` with a bearer returns `ice_servers` with `turn:` URLs.
2. Mac (B5) runs `WebRTCAcceptor` on its host socket; phone on cellular dials with `WebRTCCarrier`;
   badge shows `p2p` on the same LAN, `turn` with `iceTransportPolicy relay` forced from the DEV menu.
3. Roam Wi-Fi to cellular mid-terminal: ICE restart keeps the session (`pathChanged`), or the
   session reconnects and resumes with no gap.
4. MITM check: a dev relay build that rewrites SDP fingerprints must fail every connect with
   `auth` errors on both ends.

## 12. Not in this lane

Mac app wiring and the host socket owner (B5), key provisioning and the trust store (B6), browser and
VNC encoders and renderers (C2, C3; this lane gives them track handles), the badge UI (C11, D1),
V1 vs V2 measurements (D2).
