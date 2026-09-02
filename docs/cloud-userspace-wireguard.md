# Userspace WireGuard for Cloud VM attach

Cloud VMs live on the owner's Freestyle VPC and open no public port. Today the
only way to reach a VM's cmux-tui daemon (`ws://[<vpc ipv6>]:1337/v1/link`) is a
system WireGuard interface (`cmux vpn up`, sudo, wireguard-tools). The phone
has no such path at all: iOS needs the NetworkExtension entitlement and a VPN
prompt for a system tunnel.

This design adds an in-process WireGuard transport so a cmux client reaches a
VM with no system interface, no root, and no VPN prompt. Only cmux's own link
goes through it. Safari previews and `ssh` still need the system tunnel.

## Shape

```
cmux-remote DirectWebSocketProvider
   └─ Dialer (new seam)
        ├─ OsTcpDialer            tokio TcpStream          (default, unchanged)
        └─ WireGuardDialer        cmux-wg::WgNet::connect  (new)

cmux-wg (new crate)
   boringtun::noise::Tunn  (WireGuard, sans-IO)
   smoltcp Interface + TCP sockets (userspace TCP/IP, sans-IO)
   one tokio task drives: UDP socket <-> Tunn <-> smoltcp device
   WgNet::connect(SocketAddr) -> impl AsyncRead + AsyncWrite
```

The route stays `ws://[vpc]:1337/v1/link`. The server and the daemon are
unchanged. The client decides how to reach the address: through a system
interface if one is up, or through `cmux-wg` otherwise.

`cmux-wg` is the single implementation shared by:

- `cmux-tui remote connect --wireguard-config <path>` (the Mac sidecar),
- `cmux-terminal-client` (the in-process client the iOS app links).

## Identities

WireGuard binds one key to one peer and one endpoint. Two live sessions with
one key fight over the server's endpoint and both break intermittently. So the
in-process tunnel never shares a key with the system tunnel:

| consumer | device fingerprint | key storage | Freestyle tunnels |
| --- | --- | --- | --- |
| Mac system tunnel (`cmux vpn up`) | `mac-<uuid>` | `~/.cmuxterm/wireguard/private.key` | 1 |
| Mac in-process (sidecar) | `mac-<uuid>-app` | `~/.cmuxterm/wireguard/app.key` | 1 |
| iPhone in-process | `ios-<uuid>` | Keychain | 1 |

Cost: a Mac that uses both paths holds two Freestyle tunnels. Enrollment is
the existing `POST /api/vm/tunnel` (idempotent per fingerprint, not Pro-gated).

## Tunnel lifecycle

- Mac sidecar: one `WgNet` per `remote connect` process, up for the life of
  the link. The app passes `--wireguard-config` only when
  `VMTunnelManager.wgQuickInterfaceUp()` is false.
- iPhone: one `WgNet` while the Cloud section is in the foreground. Dropped on
  background; the next foreground re-handshakes (one round trip).
- `PersistentKeepalive = 25` while the tunnel is up. This keeps carrier NAT
  mappings alive so daemon output is not blocked. It costs one small packet
  every 25 s while the Cloud section is open.

## MTU

Freestyle hands out `MTU = 1200`. `cmux-wg` sets the smoltcp device MTU from
the config and the TCP MSS follows. The UDP path adds 32 bytes of WireGuard
overhead plus 60 bytes for the outer IPv6/UDP header.

## Sequence

1. **PR 1, `cmux-tui`:** `cmux-wg` crate, `Dialer` seam, `remote connect
   --wireguard-config`, wg-quick config parser, tests that run two `Tunn`
   peers in one process (no root, no interface).
2. **PR 2, macOS app:** app tunnel identity, enrollment, `--wireguard-config`
   on the sidecar when the system interface is down, attach no longer waits
   for `cmux vpn up`.
3. **PR 3, `cmux-terminal-client` + artifact:** `ws://` route support through
   `cmux-wg`, persistent device identity, raw terminal byte callback (the iOS
   view feeds bytes to libghostty itself; the crate's text frames are not
   used), terminal list and create, xcframework release workflow.
4. **PR 4, iOS app:** Cloud section listing the account's VMs, tunnel
   enrollment, attach through the client, bytes into `GhosttySurfaceView`.

## Non-goals

- Routing any traffic other than the cmux link (Safari previews, ssh, scp).
  These keep `cmux vpn up`.
- UDP or ICMP inside the tunnel.
- Replacing the Mac's system tunnel.
- VM create or delete from the phone, previews, files, agent chat, background
  streaming.
- A "your devices" list with revoke. The tunnel table already records each
  device; the UI comes later.

## Verification

- `cargo test -p cmux-wg`: handshake, TCP echo through two in-process peers,
  MTU-sized and larger payloads, peer restart re-handshake, config parse of
  the Freestyle-issued file.
- `cargo test -p cmux-remote`: `DirectWebSocketProvider` with an injected
  dialer reaches a daemon bound on a `WgNet` peer.
- Mac: tagged build, `cmux vpn down`, attach a private-network VM, terminal
  works, `wg show` absent.
- iPhone: Aziz, `personal` profile, dev backend, private-network VM; Cloud
  section lists VMs, tap opens a terminal, typing echoes.
