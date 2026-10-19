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
| Viewer | `Packages/Shared/CmuxScreenKit` (iOS), CmuxNext pane | Room path only today; tailnet path next |

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
- Swift viewer on the tailnet path (TailscaleKit from libtailscale, or the
  system Tailscale).
- Linux and Windows input backends.
- Consent screen and indicator in the host (remote-desktop.md 11).
- Who owns the `cmux-vnc-signal` Worker account (`debussy.workers.dev`);
  move it to the cmux Cloudflare account.
