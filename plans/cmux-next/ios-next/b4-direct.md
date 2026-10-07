# B4 `direct`: the direct-address carrier (V3)

Status: in progress on `feat-cmux-next-ios-b4-direct`, 2026-10-06. Plan: [PLAN.md](PLAN.md) section 2, B4.
Binding: [a3-link.md](a3-link.md) (carrier contract, conformance), [a0-rpc.md](a0-rpc.md) section 3.1
(byte-stream carriers add a `u32 LE` length), [a1-shell.md](a1-shell.md) (`HostsStore`),
`transport.md` (keys, paths), `OWNERSHIP-PRINCIPLES.md`.
Code: `Packages/Shared/CmuxLinkDirect` (Swift 6, iOS 17, macOS 14), depends only on `CmuxLink` and
Apple frameworks (Network, CryptoKit).

## 1. What it is

The phone dials an address the user typed or Bonjour found (Tailscale `100.64.0.0/10`,
`fd7a:115c:a1e0::/48`, MagicDNS `*.ts.net`, any WireGuard or LAN address, `_cmux._tcp` on the local
link), with no rendezvous, and the Mac proves it holds the key the phone pinned at pairing. The
carrier implements `LinkCarrier` (dialer) and `LinkAcceptor` (host) from `CmuxLink`; everything
above lanes (channels, revisions, resume, credit, priority) stays in `LinkSession`/`LinkHost`.
Every transport reports `LinkPath(kind: .direct, carrier: .direct)`, so the badge reads `direct`.

## 2. Ownership

| Fact | Owner | Others |
| --- | --- | --- |
| Host static key (X25519 private) | the Mac (`cmux link` or the app, B5), Keychain `ThisDeviceOnly` | phones pin the public key from pairing |
| Device static key (X25519 private) | the phone, Keychain `AfterFirstUnlockThisDeviceOnly`, never synced | the host's trust store keeps the public key |
| Which device keys may connect | the host's paired-device trust store (B6), consulted per handshake through `DirectAuthorizer` | the carrier holds no list |
| Direct address records (name, address, port, pinned host key) | the account's synced hosts store (`HostsStore`, C9's tab) | the carrier reads them as `LinkPeer` hints or a `DirectEndpointResolver` |
| Whether a direct route can work now | `DirectReachabilityMonitor` (NWPathMonitor events), per device | the route planner reads it |
| Bonjour advertisement | the host's `DirectAcceptor` | `DirectBrowser` mirrors it; TXT is untrusted |

## 3. Crypto choice: Noise IK over CryptoKit

`Noise_IK_25519_ChaChaPoly_SHA256`, prologue `cmux.direct/1`, the dialer is the initiator.

Why Noise and not TLS 1.3 with pinned self-signed certificates:
- TLS on Network.framework needs a `SecIdentity`, which on iOS exists only for a certificate and key
  imported into the Keychain, and a Secure Enclave key cannot sign a TLS handshake through it
  without the same Keychain dance. That means X.509 encoding, Keychain items per key and per
  rotation, and a `sec_protocol_options_set_verify_block` that throws away the PKI anyway. It also
  cannot run in an SPM test process without touching the login keychain.
- Noise pins raw 32-byte keys, which is what pairing exchanges. IK gives mutual authentication in
  one round trip (the dialer already knows the host key), hides the device key from passive
  observers, and needs no certificates.
- It matches the rest of cmux: `cmux-remote` already runs Noise (`snow`, XX/XXpsk3), and transport.md
  keys are X25519 (WireGuard). The Rust side can speak the same pattern with `snow`
  (`Noise_IK_25519_ChaChaPoly_SHA256` is a standard name).
- No vetted Swift Noise library exists, so the vetted part is the primitives: CryptoKit
  `Curve25519.KeyAgreement`, `ChaChaPoly`, `SHA256`, `HMAC`. The state machine is the ~150-line
  Noise spec (rev 34) and is pinned by the published cacophony test vector for this exact protocol
  name (handshake hash and all six ciphertexts), plus negative tests (wrong pinned key, unauthorized
  device, tampered frame, replayed message).

Bindings: msg1 payload carries `version` and the `hostID` the dialer meant to reach; the host
refuses a hostID that is not its own. The device static key arrives encrypted in msg1; the host asks
`DirectAuthorizer` (B5 plugs the paired-device store) before it answers, and closes without msg2
when refused, so an unauthorized device learns nothing past the host's key it already had. Keys
derive from the install identity in B6: the host and device publish their X25519 public key signed
by their Secure Enclave P-256 install key (Secure Enclave keys cannot be X25519, transport.md 11).
Rotation is a new key plus a trust store update; sessions re-handshake on the next connect.

## 4. Wire

TCP byte stream. Every record is `u32 LE length | body`, `length <= 65535` (Noise's message limit;
the a0-rpc length prefix convention, one level down).

- Handshake: record 1 is Noise msg1 (`e, es, s, ss` + payload `u8 version=1 | u16 LE len | hostID`),
  record 2 is msg2 (`e, ee, se` + payload `u8 version=1`). Then `Split()`.
- Transport: each record is one Noise transport message (ChaChaPoly, nonce = 32 zero bits + u64 LE
  counter, so a reordered, dropped or replayed record fails authentication and closes the transport).
  Plaintext is `u8 type | ...`:
  - `0x01 segment`: `u8 more | u8 reliability (0 reliable, 1 unordered, 2 partial) | u8 priority |
    u32 LE lifetime ms | bytes`. A frame larger than one record is split into consecutive segments;
    `more = 0` ends it. Frames are capped at `TransportCapabilities.stream.maxFrameBytes` (256 KiB).
  - `0x02 close`: graceful end; the receiver delivers everything before it, then `.closed(.remote)`.

Lane mapping: every lane rides the one stream in send order. `LinkSession` already serializes by
priority in one pump and `send` awaits the kernel's acceptance (`contentProcessed`), so a keystroke
waits at most for the frame already handed to the socket. Unreliable lanes are dropped at the sender
instead of queued when the writer is busy (unordered) or when they waited past `maxLifetime`
(partial), which keeps media semantics (no queue growth) on a reliable byte stream.

QUIC (Network.framework `NWProtocolQUIC` with datagrams and one stream per lane) would remove
TCP head-of-line blocking under loss and let unreliable lanes skip retransmission. It needs TLS 1.3
inside QUIC, which brings back the `SecIdentity` problem above (QUIC on Network.framework has no
raw-key mode). On the paths this carrier serves (LAN, and Tailscale/WireGuard, which already
encapsulate in UDP and keep loss low on a single hop) the gain is small next to that cost. D2
measures TCP under loss; if it matters, the next step is Noise-encrypted UDP datagrams for
unreliable lanes (WireGuard-style explicit counter nonce and replay window, keys from the same
`Split()`), not QUIC.

## 5. Reachability and routing

`DirectAddress` classifies what the user typed: loopback, Tailscale (CGNAT `100.64/10`,
`fd7a:115c:a1e0::/48`, `*.ts.net`), private LAN (`10/8`, `172.16/12`, `192.168/16`, `169.254/16`,
`fc00::/7`, `fe80::/10`, `*.local`), Bonjour service, or public. `DirectRouteEvaluator` is a pure
function of the address class and a `DirectPathSnapshot` (status, interface names and types) that
NWPathMonitor publishes on every change (no polling):

| Address | Available when |
| --- | --- |
| loopback | always |
| Tailscale | path satisfied and a VPN interface (`utun*`, `ipsec*`, type `other`) is up |
| private LAN | Wi-Fi or wired up, or a VPN interface (a WireGuard route to that subnet) |
| Bonjour | Wi-Fi or wired up |
| public | path satisfied |

`DirectCarrier.connect` refuses at once (`DirectCarrierError.routeUnavailable`) when the evaluator
says no, and NWConnection's `.waiting` state is a failure, so the selector never waits on a dead
direct path. `DirectRoutePlanner` gives the session its carrier list: when a direct endpoint is
configured and its route is available, only the direct carrier races (nothing else carries the
session while the direct path can work); otherwise the direct carrier is left out and the other
carriers race. The app rebuilds the selector from the planner on each snapshot and calls
`LinkSession.networkDidChange()`.

Endpoint resolution: `LinkPeer.hints` (`direct.address`, `direct.port`, `direct.hostKey`, base64)
or a `DirectEndpointResolver` (hosts store, Bonjour results joined with the paired key by hostID).
Several endpoints for one host are tried in order; the first one that completes the handshake wins.

Bonjour: `DirectAcceptor` advertises `_cmux._tcp` with TXT `v=1`, `host=<hostID>`; `DirectBrowser`
streams results. TXT is never trusted: the key always comes from pairing, so a spoofed
advertisement only fails the handshake.

## 6. API

```swift
public struct DirectIdentity: Sendable { init(); init(privateKey:); var publicKey: DirectPublicKey }
public struct DirectPublicKey: Sendable, Hashable { init(rawRepresentation:); init?(base64:); var base64: String }
public struct DirectEndpoint: Sendable, Hashable { var address: DirectAddress; var port: UInt16; var hostKey: DirectPublicKey }
public final class DirectCarrier: LinkCarrier { init(identity:, resolver:, reachability:) }
public final class DirectAcceptor: LinkAcceptor {
    init(identity:, hostID:, configuration: DirectListenConfiguration, authorizer: DirectAuthorizer)
    func start() async throws -> UInt16   // bound port
    func stop() async
}
public protocol DirectAuthorizer: Sendable { func authorize(device: DirectPublicKey) async -> Bool }
public actor DirectReachabilityMonitor { func snapshots() -> AsyncStream<DirectPathSnapshot>; func status(for:) }
public struct DirectRoutePlanner { func carriers(direct:, endpoints:, snapshot:, others:) -> [any LinkCarrier] }
public final class DirectBrowser { func results() -> AsyncStream<[DirectDiscoveredHost]> }
```

B5 hosts with `DirectAcceptor(...)` passed to `LinkHost(acceptor:)`, plus its trust store as the
authorizer. Testing hooks (`DirectFaultInjector`: drop, simulated path change, throttle) are
`@_spi(Testing)`.

## 7. Hosts hook

`HostKind.direct` gains the pinned key: `.direct(endpoint: HostEndpoint, hostKey: String)`.
`CmuxiOSFeatureKit/Hosts/DirectAddressDraft.swift` is the form model (name, address, port, host key;
validation; `hostDraft()`), and `DirectAddressFormModel` drives a small form that saves through
`HostsStore.add`. The form lives in its own files; C9 owns the Hosts tab and decides where the
"Add direct address" entry point sits.

## 8. Tests

Swift Testing in the package: Noise vector and negative cases, record codec, address classification,
route evaluator and planner, `LinkConformanceSuite` on a real localhost harness (NWListener on
`127.0.0.1:0`, NWConnection dialer, real Noise), auth refusal cases.

## 9. Not in this lane

Mac app wiring (B5), trust store and key signing (B6), the Hosts tab UI (C9), the path badge UI
(C11, D1), Rust codec (B5 if the host side moves to Rust: `snow` IK with this wire).
