# cmux next: remote desktop v2 (WebRTC media, tailnet signaling)

Status: decided by Lawrence, 2026-10-18. Replaces decision RD4 (`cmux.rd/1`)
and the transport parts of RD9 in [remote-desktop.md](remote-desktop.md).
Everything else in that file (consent, indicator, agents never control, hosts
off by default, audit) still binds. Owner: hq session cmuxterm-hq-53, worktree
`feat-cmux-next-tailnet-rd`. Base code: Abdulaziz Albahar's `cmux-screen`
(branch `feat-cmux-next-mac-screen`, 7a4a19d2df77c).

## 0. Decisions

| Id | Decision | Why |
| --- | --- | --- |
| RD2-1 | The product stays GPL-3.0-or-later. No RustDesk code and no RustDesk protocol. | RustDesk is AGPL-3.0; its protocol also brings its own ID server, relay, crypto and device ids, which duplicate Tailscale. |
| RD2-2 | Media is WebRTC (Google libwebrtc through LiveKit's `libwebrtc` crate, BSD and Apache). | Congestion control, FEC/NACK, jitter buffer, hardware encoders, data channels and browser/iOS clients come with it. Measured on macOS: keys 40-53 ms, pointer 63 ms glass to glass. |
| RD2-3 | Each host joins the user's tailnet as its own device through embedded Tailscale: libtailscale (Tailscale's Go tsnet as a C library, BSD-3), crate `cmux-tailnet`. Not tailscale-rs (pre-alpha, "unstable and insecure"). | Works with no Tailscale app installed, the same way Rex does it: a sign-in link once, the login kept on disk, a MagicDNS name `cmux-<computer>.<tailnet>.ts.net`. |
| RD2-4 | Signaling (offer, answer, candidates) goes over the tailnet: a WebSocket on tailnet port 4180, plain inside WireGuard. | WireGuard encrypts it and authenticates the peer's node key, so the SDP and its DTLS fingerprint come unmodified from the identified device. No link secret. |
| RD2-5 | The Cloudflare Worker room (`cmux-vnc-signal`) and Cloudflare TURN stay only as the fallback for a viewer with no tailnet. | Phones and machines that cannot join the tailnet still work. A tailnet viewer is never displaced by a room offer. |
| RD2-6 | cmux-wg (our userspace WireGuard) stays for Cloud VMs and Freestyle. Tailscale is for user devices. | The Cloud VM path already uses cmux-wg and Freestyle tunnels. |

## 1. Security model

Five checks, in order. Each one only narrows.

1. Tailscale ACLs (the user's tailnet policy) decide reachability.
2. The host's tsnet listener accepts only on its tailnet addresses (never a
   LAN or public interface).
3. WhoIs on the peer address, then `cmux_tailnet::Access`, before the
   WebSocket handshake: deny list, then the node's owner (same Tailscale user
   id), then the allow list (`user:<login>` or `tag:<name>`), then tailnet
   members only with `--allow-tailnet-members`. Tagged devices have no owner
   and pass only by an explicit `tag:` entry. Default deny.
4. The WebSocket handshake is refused when it carries a browser `Origin`
   header. WhoIs names the device, not the program: without this rule a web
   page that the owner opens could reach the port as the owner. A peer that
   does not finish the handshake in 10 s is dropped.
5. Session rules from remote-desktop.md section 11: hosting off by default,
   consent at the host, the indicator with Stop, no agent control, audit.

Fallback path: the room secret (256 bits) authenticates the room, the Worker
sees signaling only, TURN carries DTLS-SRTP ciphertext only.

The sign-in link is a credential until someone uses it: whoever opens it
first puts the device on their own tailnet and becomes its owner. So the link
goes only to the IPN bus reader (the CLI, later the app's sign-in button),
never to a log. tsnet prints it every 5 s through `UserLogf`, which
libtailscale does not expose; `cmux-tailnet/patches/0001-user-logf-follows-logfd.patch`
routes it to the log fd (discarded by default). The node state folder is
0700. The LocalAPI client never uses an environment proxy (it would receive
the LocalAPI password).

## 2. Components

| Piece | Where | State |
| --- | --- | --- |
| `cmux-tailnet` | `cmux-screen/crates/cmux-tailnet` | Node (start, status, IPN bus watch, TCP listen/dial, WhoIs), `Access`, CLI `cmux-tailnet up/serve/dial` |
| Tailnet signaling | `cmux-screen-host/src/tailnet_signal.rs` | Listener, WhoIs + Access before the handshake, same `SignalMessage` as the room |
| Host | `cmux-screen-host` | Both sources; tailnet on by default; `--no-room` turns off the fallback |
| Capture and input | `cmux-screen-host/src/backend` | macOS done (ScreenCaptureKit, CGEvent). Linux and Windows: capture builds, input not done |
| Viewer | `Packages/Shared/CmuxVNCWebRTC`, `CmuxScreenKit`; CmuxNext pane | Room and tailnet paths in the shared packages (section 8); the CmuxNext pane needs the PKG landing |

`cmux-screen` is its own Cargo workspace, like `cmux-rd-host`, so libwebrtc
and the Go toolchain do not enter the cmux-tui lockfile.

## 3. Media path on a tailnet

- Both ends with the Tailscale app (system Tailscale): the OS has a tailnet
  interface, so ICE host candidates include 100.x / fd7a: addresses and the
  stream runs directly over WireGuard. No TURN.
- A host with embedded Tailscale only: libwebrtc cannot use tsnet's userspace
  network stack, so its ICE candidates are LAN and STUN/TURN ones (the room's
  fallback servers). Signaling and identity still go over the tailnet.
  Next step (RD2-7, open): carry media through tsnet too, by a small
  loopback bridge: the viewer gets a TURN-over-TCP server on loopback that
  forwards over a tsnet TCP stream to a TURN server inside the host. That
  keeps libwebrtc unchanged. A datagram variant needs a `ListenPacket` export
  added to libtailscale (tsnet has `ListenPacket`; libtailscale's C API has
  only stream sockets).
- MTU: the Tailscale MTU is 1280, so the RTP payload must stay at or under
  1200 bytes on that path (libwebrtc's default packet size fits).

## 4. Onboarding

The sign-in button from the onboarding plan maps to one daemon op:
`tailnet.login.start` returns the `BrowseToURL` from the IPN bus; the app
opens it; `tailnet.state` events report NeedsLogin, Running (with the MagicDNS
name and owner), and NeedsMachineAuth. The daemon owns the node (one per
install, state in the daemon state folder); the screen host and other
services use its listener. This slice touches cmux-tui and needs the chief's
LOCK turn.

## 5. Build

- `cmux-tailnet/build.rs`: `LIBTAILSCALE_A` (prebuilt), else
  `LIBTAILSCALE_SRC`, else the pinned upstream commit
  d1dc45d039edb7759ecbee6ba2aea0c4bca884b8 (Tailscale v1.104.1), built with
  `go build -buildmode=c-archive`. Needs Go 1.27.
- Release builds must use `LIBTAILSCALE_A` from a cached, checksummed build;
  a network fetch during a release build is not allowed.

## 6. Verification

- `cmux-tailnet serve` on host A and `cmux-tailnet dial cmux-a.<tailnet>.ts.net:4180`
  on B: B gets `allowed ... owner`; a device of another user gets `denied`.
- `cmux-screen-host` on a Mac, viewer on the tailnet: offer and answer over
  the tailnet, log line `tailnet user:<login> viewer offered`.
- Room fallback: the iOS app with the pairing link, unchanged behavior.

## 7. Open

- RD2-7: media through tsnet for embedded-only hosts (section 3).
- The CmuxNext Mac Screen pane on the tailnet path: the PKG landing in
  section 8.
- Linux and Windows input backends.
- Consent screen and indicator in the host (remote-desktop.md 11).
- Who owns the `cmux-vnc-signal` Worker account (`debussy.workers.dev`);
  move it to the cmux Cloudflare account.

## 8. Viewer

Branch `feat-cmux-next-tailnet-viewer` brings Abdulaziz Albahar's Swift
packages from `feat-cmux-next-mac-screen` (7a4a19d2df77c):
`Packages/Shared/CmuxVNC`, `CmuxVNCWebRTC` and `CmuxScreenKit` (manifests
at tools version 6.0). The CmuxNext Mac Screen module
(`Sources/CmuxNextMacScreen`) is not on this branch: it needs
`Packages/macOS/CmuxNext/Package.swift`, which is frozen (PKG slot).

### 8.1 API (CmuxVNCWebRTC, re-exported by CmuxScreenKit)

| Type | Meaning |
| --- | --- |
| `ScreenEndpoint` | `.room(VNCPairing)` (the Worker room, fallback) or `.tailnet(TailnetScreenTarget)` |
| `TailnetScreenTarget` | `name`, `host` (MagicDNS name `cmux-<computer>.<tailnet>.ts.net`), `port` (default 4180), `route`, `fallbackRoom: VNCPairing?` (only a source of ICE servers) |
| `TailnetRoute` | `.daemonForward` (default) or `.systemTailscale` (dial the MagicDNS name through the system Tailscale interface) |
| `TailnetForwarding` | protocol the app implements on the daemon client: `forward(target: "host:port") async throws -> TailnetLocalEndpoint` |
| `TailnetLocalEndpoint` | `.tcp(host:port:)` (loopback only) or `.unix(path:)`; decodes the op result `{"tcp":"127.0.0.1:PORT"}` or `{"unix":"/path"}` |
| `TailnetSignalError` | `noForwarding`, `forwardFailed`, `unreachable`, `closed`; the pane maps each case to localized text |
| `ScreenStreamViewer(endpoint:forwarding:relayOnly:)` | the viewer; `init(pairing:relayOnly:)` stays for the room |
| `ScreenSession(title:tailnet:forwarding:preferences:)` | a session to a tailnet host; `isTailnet` for the path label |

The tailnet signaling link (`TailnetSignalSocket`) is a Network.framework
WebSocket (`NWConnection` with `NWProtocolWebSocket`) to the local forward
or to `host:4180`. It adds no header, so the handshake has no `Origin`
(section 1, check 4). Network.framework, not `URLSessionWebSocketTask`,
because it also dials a Unix socket and App Transport Security does not
apply to plain `ws://` on a MagicDNS name. (`URLSessionWebSocketTask` also
sends no `Origin` by default.) Liveness: TCP keepalive (20 s idle) and
automatic replies to the host's pings; no timer in the viewer.

### 8.2 Signaling on the tailnet path

Same `SignalMessage` JSON as the room, one link per session:

1. Host: optional `{"type":"ice","iceServers":[{"urls":[...],"username":...,"credential":...}]}`,
   then `{"type":"hello","role":"viewer","peer":true}`.
2. Viewer: makes the peer connection with the `ice` servers; when the host
   sent none, with the `fallbackRoom`'s servers (`GET /v1/rooms/<room>/ice`);
   with neither, no servers (host candidates only, enough when both ends
   have system Tailscale). Then `offer`; the host sends `answer`; both send
   `candidate`.
3. An `ice` after the offer goes to `RTCPeerConnection.setConfiguration`;
   libwebrtc uses it from the next gathering. The host must send `ice`
   before `hello` so the first gathering has it.
4. The room path ignores `ice` (its servers come from the Worker).
5. Once the stream is open, the signaling link closing does not end it.
   Before open, a closed link fails the connect (`TailnetSignalError`).

Host side (another lane): `cmux_screen_proto::SignalMessage` needs
`#[serde(default, rename = "iceServers", skip_serializing_if = "Option::is_none")] ice_servers: Option<Vec<IceServer>>`,
and `tailnet_signal::viewer` sends `ice` before `hello`.

### 8.3 Daemon op the viewer uses

`tailnet.forward {"target":"cmux-<computer>.<tailnet>.ts.net:4180"}` returns
`{"tcp":"127.0.0.1:PORT"}` or `{"unix":"/path"}` (the daemon owns the node,
section 4). Open: how long a forward lives (per daemon connection, or a
`tailnet.forward.close`). The viewer asks for a new forward on each
connect.

### 8.4 PKG landing: Package.swift

In `Packages/macOS/CmuxNext/Package.swift`, as on Aziz's branch:

```swift
// dependencies:
        .package(path: "../../Shared/CmuxVNC"),
        .package(path: "../../Shared/CmuxScreenKit"),
// targets:
        .target(
            name: "CmuxNextMacScreen",
            dependencies: ["CmuxNextCompat", "CmuxNextSettings", "CmuxNextWakeups", "CmuxNextActions", "CmuxNextControl", "CmuxNextDesign", "CmuxNextRemoteView", .product(name: "CmuxScreenKit", package: "CmuxScreenKit")],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
// CmuxNextApp dependencies: add
                "CmuxNextMacScreen",
```

Plus the dependency-direction comment lines for `CmuxNextMacScreen` and
`CmuxVNC`. CmuxScreenKit links `WebRTC.xcframework` (stasel/WebRTC M154,
a binary target in CmuxVNCWebRTC): the app's embed and signing phases must
include it, which may need a `*.pbxproj` change (pbxproj slot). Aziz's
branch also adds `CmuxNextMacScreen` and `CmuxVNC` to `CmuxNextAppTests`;
skip that (no new unit tests).

### 8.5 PKG landing: Mac Screen pane

Port `Sources/CmuxNextMacScreen/*` from Aziz's branch (it uses
`public nonisolated struct`, Swift 6.1; CmuxNext is tools 6.2, so it
compiles, but it is not Swift 6.0 code), then:

1. `SavedMac` gets `tailnet: TailnetScreenTarget?` (no secret; it can stay
   in the JSON file). A Mac with `tailnet` set connects over the tailnet;
   its Keychain pairing, when present, becomes `fallbackRoom`.
2. `MacScreenPane.init(name:target:forwarding:preferences:confirmed:)`
   calls `ScreenSession(title:tailnet:forwarding:preferences:)`; the
   pairing init stays.
3. `MacScreenPages.makePane` picks the tailnet init when `mac.tailnet` is
   set. `MacScreenPages` gets a `forwarding: (any TailnetForwarding)?`
   from the App.
4. CmuxNextApp implements `TailnetForwarding` on its `DaemonConnection`
   (a `DaemonRequest` for `tailnet.forward`, `requiredCapability`
   `"tailnet.forward"`, response decoded as `TailnetLocalEndpoint`).
   Feature modules do not import CmuxNextDaemon.
5. Home page: the daemon's tailnet peers that run a screen host (a later
   `tailnet.peers` op) are listed as Macs to add; "Add by name" takes a
   MagicDNS name. Until that op exists, a debug-only field.
6. Path label: `session.isTailnet` shows "Tailnet" before "Direct/Relay".
7. Localized strings (Localizable.xcstrings, all locales):
   `macScreen.path.tailnet` "Tailnet";
   `macScreen.error.tailnetNoDaemon` "cmux is not connected to its background service.";
   `macScreen.error.tailnetForward` "This Mac is not on your tailnet. Sign in to Tailscale in Settings.";
   `macScreen.error.tailnetUnreachable` "The Mac did not answer on your tailnet. It may be off, or it may not allow this device.";
   `macScreen.error.tailnetClosed` "The Mac closed the connection.";
   `macScreen.home.addByName` "Add by Tailscale name".

### 8.6 Verification state

- Compiled headless on the fleet (cmux-ci steps in the branch's landing
  report). Not run against a live host.
- UNVERIFIED: the WebSocket over a Unix-socket forward; the handshake
  against `tailnet_signal.rs` (no `Origin`, 101); an `ice` after the offer.

