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
| `cmux-tailnet` | `cmux-screen/crates/cmux-tailnet` | Node (start, status, IPN bus watch, TCP listen/dial, WhoIs), `Access`, media relay (`relay`, feature), CLI `cmux-tailnet up/serve/dial/forward/turn-serve/turn-check` |
| Tailnet signaling | `cmux-screen-host/src/tailnet_signal.rs` | Listener, WhoIs + Access before the handshake, same `SignalMessage` as the room |
| Host | `cmux-screen-host` | Both sources; tailnet on by default; `--no-room` turns off the fallback |
| Capture and input | `cmux-screen-host/src/backend` | macOS done (ScreenCaptureKit, CGEvent). Linux and Windows: capture builds, input not done |
| Viewer | `Packages/Shared/CmuxScreenKit` (iOS), CmuxNext pane | Room path only today; tailnet path next |

`cmux-screen` is its own Cargo workspace, like `cmux-rd-host`, so libwebrtc
and the Go toolchain do not enter the cmux-tui lockfile.

## 3. Media path on a tailnet

- Both ends with the Tailscale app (system Tailscale): the OS has a tailnet
  interface, so ICE host candidates include 100.x / fd7a: addresses and the
  stream runs directly over WireGuard. No TURN.
- A host with embedded Tailscale only: libwebrtc cannot use tsnet's userspace
  network stack, so its own ICE candidates are LAN and STUN/TURN ones.
  RD2-7 (built, branch `feat-cmux-next-tailnet-media`) carries the media over
  the tailnet anyway, with libwebrtc unchanged on both ends:

  ```
  viewer libwebrtc --TURN/TCP--> 127.0.0.1:P (viewer forward) --tsnet TCP--> host:4181
      host relay (webrtc-rs turn) --UDP on this machine--> host libwebrtc host candidate
  ```

  - Host: `cmux_tailnet::relay::TurnRelay` (feature `relay`) listens on
    tailnet port 4181 (`--tailnet-relay-port`, `--no-tailnet-relay`). Each
    TCP connection gets WhoIs + `Access` (the signaling rule), then its own
    TURN server instance (webrtc-rs `turn` 0.17, MIT OR Apache-2.0), so its
    allocations end with the connection. Relays are IPv4 UDP sockets on this
    machine.
  - Credentials: per admitted signaling link, random username (96 bits) and
    password (192 bits), bound to the link's WhoIs node (stable id): another
    device with the same credentials is refused. At most 8 connections per
    credential; a connection that does not authenticate in 10 s is dropped.
    The link and the WebRTC session each hold the credential; when both
    end, it is revoked and its connections and allocations close at once.
  - Relay egress: only to the exact UDP host candidates of the session the
    host itself gathered (from `on_ice_candidate` and the answer SDP);
    datagrams from other sources are dropped. So the relay is not an open
    relay into the host's LAN or its local services.
  - Protocol: one new tailnet-only `SignalMessage` kind, sent before `hello`
    (the viewer builds its peer connection on `hello`):
    `{"type":"ice","iceServers":[{"urls":["turn:100.x.y.z:4181?transport=tcp"],"username":"…","credential":"…"}]}`.
    A viewer with the Tailscale app uses the URL as is; a viewer with only an
    embedded node forwards a loopback port to that host:port and puts
    `turn:127.0.0.1:P?transport=tcp` in its configuration. The room never
    carries `ice`: the Worker path and the iOS app are unchanged.
  - Viewer reference: `cmux-tailnet forward --state DIR --local 127.0.0.1:P HOST:PORT`
    (loopback only) reaches 4180 and 4181 through the viewer's own node. The
    product version is a daemon op.
  - Check: `cmux-screen/scripts/tailnet-turn-check.sh host` on one node and
    `... viewer --target HOST:4181 --user U --pass P --peer IP:PORT` on the
    other: forward, TURN Allocate over TCP, one datagram to a UDP echo on the
    host and back (`turn-check ok: ...`).

  Limits:
  - The tailnet leg is TCP: a lost packet stalls the stream behind it
    (head-of-line blocking) and congestion control runs twice. Fine on a
    healthy tailnet path; worse than UDP on a lossy one. ICE still prefers a
    direct LAN or OS-tailnet pair when one works (relay candidates rank last).
  - IPv4 relays only; a host with only IPv6 host candidates gets no relay path.
  - The relay address reported to the viewer is the address of the default
    route; on a multi-homed host the host's libwebrtc may first see the
    relay as a peer-reflexive candidate (ICE still connects).
  - A viewer's other local programs can use its loopback forward, the same
    trust as signaling ("WhoIs names the device, not the program"), but they
    still need the per-link credential, which only the signaling link gets.
  - A datagram variant (lower latency on loss) needs a `ListenPacket` export
    added to libtailscale (tsnet has `ListenPacket`; libtailscale's C API has
    only stream sockets).
- MTU: the Tailscale MTU is 1280. On the relay path the tailnet leg is TCP,
  so TCP segments the TURN frames and the MTU never limits RTP; the host leg
  is UDP on one machine. libwebrtc's default RTP packet size (about 1200
  bytes) also fits a future datagram path (1280 - 40 IPv6 - 8 UDP - 4
  ChannelData = 1228 bytes).

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
- Media relay: `cmux-screen/scripts/tailnet-turn-check.sh` on two signed-in
  nodes (section 3); with the screen host, the log line
  `media relay (TURN over TCP) on tailnet port 4181`.

## 7. Open

- RD2-7: built (section 3). Open: a tailnet viewer (Swift or CmuxNext) that
  reads `ice` and runs the forward; a libwebrtc-to-libwebrtc run over the
  relay with measured latency against the room's TURN.
- Swift viewer on the tailnet path (TailscaleKit from libtailscale, or the
  system Tailscale).
- Linux and Windows input backends.
- Consent screen and indicator in the host (remote-desktop.md 11).
- Who owns the `cmux-vnc-signal` Worker account (`debussy.workers.dev`);
  move it to the cmux Cloudflare account.
