# B3 `webrtc-wg`: WireGuard over a WebRTC underlay (carrier V2)

Status: landed (local) on `feat-cmux-next-ios-b3-webrtc-wg`, 2026-10-06. Plan: [PLAN.md](PLAN.md) B3.
Binding: [a3-link.md](a3-link.md) (carrier contract, conformance), [b1-control-do.md](b1-control-do.md)
(signal relay section 5, TURN minting section 6), [b4-direct.md](b4-direct.md) (pinned X25519 keys),
`transport.md` (sections 0, 3.1, 8, 10, 12a). Code: `Packages/Shared/CmuxLinkWG` (Swift 6, iOS 17,
macOS 14), depends only on `CmuxLink` and CryptoKit.

## 1. What it is

Every V2 stream is end-to-end WireGuard: one WireGuard session per device and host, keyed by the
install's X25519 key and the host key the phone pinned at pairing. WebRTC only finds and holds the
path: ICE does NAT traversal, Cloudflare TURN (minted by B1) relays when no pair connects, and
WireGuard datagrams ride one unreliable, unordered data channel. The A3 lanes run inside the
WireGuard session as a small reliable-datagram protocol. The DO signaling relay, TURN, and the
DTLS layer under the data channel all carry WireGuard ciphertext; none of them can read or forge a
lane frame. That is what V2 adds over V1: V1's DTLS fingerprints travel through the signaling relay,
so V1 is only as trustworthy as the relay unless it binds fingerprints to device keys.

```
feature -> LinkSession (channels, revisions, resume, credit)          CmuxLink (A3)
  -> WireGuardLinkTransport: lanes (ARQ, priority pump, fragmentation)  CmuxLinkWG
  -> overlay IPv6/UDP datagram to [host overlay addr]:4104             CmuxLinkWG
  -> WireGuardTunnel (Noise_IKpsk2, counters, replay window, rekey)     CmuxLinkWG
  -> DatagramUnderlay: one WebRTC data channel {ordered:false, maxRetransmits:0}   B2 adapter
  -> ICE: host/srflx pair (p2p) or Cloudflare TURN (turn)
```

## 2. Layering: which order

Two ways to combine the two:

| | A: WireGuard inside a WebRTC data channel | B: WebRTC (ICE) over the WireGuard overlay |
| --- | --- | --- |
| Shape | WebRTC opens a peer connection; each WireGuard datagram is one data channel message | the overlay (`cmux-wg`, transport.md) runs over UDP; WebRTC's ICE candidates are overlay addresses |
| iOS without a Network Extension | yes: libwebrtc and the WireGuard engine both run in the app on bytes | no in practice: libwebrtc binds OS sockets. An overlay address exists only inside our userspace stack, so ICE would need a custom packet socket factory inside libwebrtc's C++ (not in the ObjC SDK) or a `utun` from a packet tunnel |
| NAT traversal | ICE + TURN, already built by B2 | the overlay's own (STUN, rendezvous, DO relay); WebRTC adds nothing but a second, redundant path search |
| Security boundary | WireGuard, end to end; DTLS is an outer layer we do not trust | WireGuard; WebRTC's DTLS inside it is redundant |
| Overhead | DTLS + SCTP + WireGuard (about 32 B + padding per datagram) | same layers, inverted |

We build A. It is the only order that runs in the app process on iOS without a VPN slot, and it
keeps WireGuard as the security boundary, which is the property the variant exists for. PLAN.md's
wording ("WebRTC session carried over the overlay") describes B; this note supersedes it.

## 3. Ownership

| Fact | Owner | Others |
| --- | --- | --- |
| Device WireGuard key (X25519 private) | the phone, Keychain `AfterFirstUnlockThisDeviceOnly`, never synced; the public key is signed by the Secure Enclave P-256 install key (transport.md 8) | the host's trust store keeps the public key |
| Host WireGuard key | the Mac (`cmux link` or the app, B5) | phones pin it at pairing (B6), passed as `LinkPeer.hints["wg.hostKey"]` or a `WireGuardHostKeyResolver` |
| Which device keys may complete a handshake | the host's paired-device trust store, asked per handshake through `WireGuardAuthorizer` | the carrier holds no list |
| WireGuard session state (indices, keys, counters, replay window) | the `WireGuardTunnel` inside one `WireGuardLinkTransport` | nothing else |
| The underlay (peer connection, ICE pair, TURN use) | B2's WebRTC stack behind `DatagramUnderlay` | the transport reads its path and events |
| Signaling (offer, answer, ICE) | B1's `HostDO` relay, through `SignalingChannel` | the underlay adapter |

One key per install, used by both B4 (Noise IK) and B3 (WireGuard), is transport.md's rule ("one
WireGuard key"). Both protocols hash distinct construction names into every key derivation, so the
reuse does not let one protocol's messages pass as the other's. B6 decides; until then each lane
takes the key as a parameter.

## 4. WireGuard engine: Swift, wire-compatible

`cmux-wg` (Rust, boringtun + smoltcp) already ships inside the `CmuxTerminalClient` xcframework.
Reusing it from Swift would need a new C ABI (a sans-IO wrapper around `Tunn`) and an xcframework
release per change; the Swift tests could not run without that binary, and its TCP stack (smoltcp,
no SACK, the measured upload defects in transport.md 16) is the part we do not want. The Mac side of
V2 is likely Swift too (B5 embeds `LinkHost` in the app for the browser host).

So `CmuxLinkWG` carries a Swift engine, `WireGuardTunnel`, that speaks the WireGuard wire format
(message types 1, 2, 4; `Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s`, the identifier and labels of the
whitepaper, mac1, TAI64N, 2048-bit replay window, REKEY/REJECT timers) so a `cmux-wg` host
interoperates. Primitives: CryptoKit `Curve25519.KeyAgreement` and `ChaChaPoly`; BLAKE2s (CryptoKit
has none) is about 120 lines, checked against RFC 7693 and against Python's `hashlib.blake2s`
(keyed and unkeyed, HMAC). Binary cost is tens of KB, against 0 for the FFI route (boringtun is
already linked) plus an FFI hop per datagram. The API mirrors boringtun's `Tunn`
(`encapsulate`, `decapsulate`, `updateTimers`) so a boringtun-backed engine can replace it behind
the same transport if D2 or a security review asks for it.

Not implemented: cookie replies (type 3, the under-load DoS defence). A received cookie reply is
ignored. Underlays exist only after B1 admission (same account or team), which bounds the flood
surface; a host under handshake load drops instead of answering with cookies.

Interop proof: `cmux-tui/crates/cmux-wg/tests/swift_interop.rs` feeds a Swift-made initiation
(fixed keys and ephemeral, golden bytes from this package's tests) into boringtun's `Tunn`, which
must answer with a 92-byte response. That checks mac1, the static and timestamp AEADs and the whole
hash chain. Not run locally (no cargo on this Mac); CI runs it with the crate's tests.

## 5. Streams inside the tunnel: reliable datagrams, not a netstack

Choices for carrying A3 lanes inside WireGuard:

1. A userspace TCP/IP stack (what `cmux-wg` does with smoltcp): one TCP connection per reliable
   lane. Swift has no netstack; smoltcp through FFI brings back the binary and its defects. TCP also
   cannot carry unreliable lanes, so media would need UDP beside it anyway.
2. A minimal reliable framing over WireGuard datagrams (chosen). `LinkSession` already owns
   everything above one transport (resume, cursors, credit, priority, gaps), so the carrier only
   needs per-transport lanes that keep A3's promises. That is a small selective-repeat ARQ.

Each lane frame rides one overlay datagram: IPv6 (`fd7c:6d78::/32` + 96 bits of SHA-256 of the
install or host id, transport.md 3.1) and UDP to port 4104 (service `link-lanes`), checksummed. The
48 bytes buy compatibility: boringtun only accepts IP plaintext, and a `cmux-wg` host receives
these through its datagram service (transport.md 12a) and runs the same lane protocol (B5).

Lane wire (`u8 version = 1 | u8 type | ...`, little-endian):

| Type | Body |
| --- | --- |
| `1 data` | `u8 lane | u8 flags (bit0 first, bit1 last) | u32 seq | payload`. Reliable lanes number fragments; unordered and partial lanes number messages and add `u16 index | u16 count` |
| `2 ack` | `u8 lane | u32 next expected seq | u64 SACK bitmap (bit i = next+1+i received)` |
| `3 close` | graceful end, sent after every reliable fragment is acknowledged |
| `4 closeAck` | |

`lane` = reliability (`0` reliable, `1` unordered, `2` partial) << 4 | priority. One reliable lane
per priority; frames up to `maxFrameBytes` (256 KiB) are split into fragments that fit the
underlay MTU (default 1200 B per WireGuard datagram, one SCTP chunk, so loss is per fragment).

Sender: per reliable lane a window of unacknowledged bytes (default 1 MiB); `send` suspends past it
(back-pressure). Retransmission on RTO (smoothed RTT, Karn's rule, 50 ms floor, doubling to 2 s)
and on three SACKs past a hole. One pump per transport drains a strict priority queue (acks, then
input > control > render > media > bulk) into the underlay, so a keystroke waits behind at most the
datagram already handed to the data channel. Unordered queues drop their oldest past 512 datagrams;
partial datagrams older than `maxLifetime` are dropped at dequeue. Receiver: in-order delivery per
reliable lane with an out-of-order buffer of the window; acks coalesce (one per pump turn per lane).

Timers: one one-shot sleep per transport on the injected `LinkClock`, armed for the earliest of the
RTO deadline and the WireGuard timers (handshake retry, rekey, keepalive after receive). An idle
transport with nothing unacknowledged arms nothing.

## 6. Handshake, rekey, roaming

- Connect: `DatagramUnderlayDialer.open(peer)` gives an underlay (B2: signaling + ICE + data channel
  `wg`); the transport sends a handshake initiation, retries every `rekeyTimeout` (5 s, new
  ephemeral each time) until `connectTimeout`, then sends a keepalive so the responder confirms the
  new keys. `connect` returns after the response; the path is the underlay's (`p2p` or `turn`).
- Accept: `DatagramUnderlayListener.incoming` yields underlays; the acceptor reads the first
  datagram. An initiation from a key `WireGuardAuthorizer` allows creates a transport, yielded on
  `incoming` once the initiator's first data packet confirms the keys.
- Rekey: WireGuard's rules (initiator rekeys on send after 120 s or 2^60 messages, either side
  answers an initiation at any time, keys rejected after 180 s, previous keypair kept for in-flight
  packets). Lane state is untouched; a rekey is invisible above the tunnel.
- Path change (ICE switched pair, ICE restart to TURN): the underlay reports
  `.pathChanged(kind)`; the transport emits `.pathChanged` and keeps the session.
- Underlay loss (`.closed(.pathLost)`, the peer connection died): the dialer opens a new underlay
  within `rebindWindow` (default 10 s) and sends one data packet under the current keys; the host's
  acceptor routes a first datagram of type 4 by its receiver index to the live transport, which
  adopts the new underlay only after that packet authenticates and passes the replay window (so a
  replayed packet cannot steal the path). Lost fragments are retransmitted; no WireGuard handshake,
  no `LinkSession` reconnect. If no underlay comes back in the window, or keys expired, the
  transport closes with `.pathLost` and `LinkSession` reconnects and resumes as usual.
- `.closed(.reset)` (the peer said `bye`, or the harness hard-drops) closes the transport at once.

## 7. API

```swift
public struct WireGuardPrivateKey { init(); init(rawRepresentation:) throws; var publicKey: WireGuardPublicKey }
public struct WireGuardPublicKey: Hashable { init?(rawRepresentation:); init?(base64:); var base64: String }
public protocol WireGuardAuthorizer { func authorize(peer: WireGuardPublicKey) async -> Bool }
public struct WireGuardPinnedAuthorizer: WireGuardAuthorizer

public protocol DatagramUnderlay: Sendable {
    var path: PathKind { get async }                 // .p2p or .turn
    var maxDatagramBytes: Int { get }                // the data channel message budget
    var events: AsyncStream<UnderlayEvent> { get }   // datagram, pathChanged, closed(pathLost|reset|local)
    func send(_ datagram: Data) async throws         // suspends while the channel buffer is full
    func close() async
}
public protocol DatagramUnderlayDialer: Sendable { func open(to peer: LinkPeer) async throws -> any DatagramUnderlay }
public protocol DatagramUnderlayListener: Sendable { var incoming: AsyncStream<any DatagramUnderlay> { get } }
public protocol SignalingChannel: Sendable {       // B1 signal frames; B2 implements on CmuxControlPlane
    func send(_ message: SignalingMessage) async throws
    func messages() -> AsyncStream<SignalingMessage>
}

public final class WireGuardOverWebRTCCarrier: LinkCarrier {   // kind .webrtcWireGuard, paths [.p2p, .turn]
    init(identity: WireGuardPrivateKey, underlays: any DatagramUnderlayDialer,
         hostKeys: any WireGuardHostKeyResolver = WireGuardHintsResolver(), configuration: WireGuardLinkConfiguration = .init(), clock: LinkClock = .continuous)
}
public final class WireGuardOverWebRTCAcceptor: LinkAcceptor {
    init(identity:, hostID:, underlays: any DatagramUnderlayListener, authorizer:, configuration:, clock:)
    func start() async; func stop() async
}
public actor WireGuardLinkTransport: LinkTransport { var remoteKey: WireGuardPublicKey }
```

`CmuxLinkWGTesting` adds `InMemoryUnderlayNetwork` (seeded loss, duplication, reorder, latency,
jitter, rate limit; `changePath`, `roam`, `reset`) and `WireGuardConformanceHarness`.

Coordination with B2: B2 had no commits when this landed, so `SignalingChannel` and
`DatagramUnderlay` are defined here. `SignalingMessage` mirrors B1's `signal {kind, session, to,
from?, body}` field for field, so B2's control-plane signaling conforms with a field copy. B2's part
is one adapter: an `RTCPeerConnection` with one data channel `wg` (`ordered: false,
maxRetransmits: 0`) conforming to `DatagramUnderlay`, its selected candidate pair type mapped to
`.p2p`/`.turn`, `RTCPeerConnectionState.failed` to `.closed(.pathLost)` and a signaled `bye` to
`.closed(.reset)`. V1 and V2 then share the peer connection code, the TURN credentials and the
signaling; only the channel set differs.

## 8. Media

Media tracks over V2 are unsupported in this lane (`capabilities.carriesMedia == false`, so
`LinkSession` answers `unsupportedOnPath`). Carrying WebRTC media tracks would put them outside
WireGuard. C2/C3 can send encoded frames on unreliable `media` channels instead, which V2 carries;
D2 decides whether that is acceptable or whether V2 stays a terminal and file path.

## 9. Tests

`swift test` in `Packages/Shared/CmuxLinkWG`:
- BLAKE2s, HMAC-BLAKE2s and KDF against RFC 7693 and Python `hashlib` vectors.
- Handshake: both sides derive the same keys, 148/92-byte messages, mac1 rejection, unknown or
  unauthorized initiator, wrong pinned host key, tamper, replayed initiation (timestamp), replayed
  and reordered data within the window, golden initiation bytes for the Rust interop test.
- Rekey: after 120 s of simulated time the initiator rekeys under traffic, indices change, no packet
  is lost, the previous keypair still decrypts in-flight packets; keys past 180 s are rejected and
  the next send re-handshakes.
- Lanes: fragment/reassembly round trips, ARQ over 20 % loss with reorder and duplication.
- Roaming: an ICE path change and an underlay replacement keep the WireGuard session (same
  receiver index, no new handshake) and every reliable fragment.
- `LinkConformanceSuite`, all seven cases, over the in-memory underlay with seeded loss, reorder
  and jitter.

## 10. Risks and open items

- Own composition of WireGuard in Swift: primitives are CryptoKit, BLAKE2s is vector-checked, the
  protocol is checked against boringtun only through the Rust interop test in CI. A security
  review before V2 carries user traffic.
- No cookie replies (section 4). No congestion control beyond the fixed window and RTO backoff;
  over TURN at high RTT a 1 MiB window caps throughput (about 80 Mbit/s at 100 ms). D2 measures.
- Double encryption (DTLS + WireGuard) costs CPU on bulk; D2 measures battery against V1.
- The real WebRTC underlay is B2's adapter; conformance over real loopback WebRTC runs when B2
  lands (`WireGuardConformanceHarness` takes any dialer and listener).
- B5 must implement the lane protocol on the Mac (Swift: reuse this package; Rust: the overlay
  datagram service on port 4104).
