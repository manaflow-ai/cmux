# Cloud private network access

Cloud VMs live in the account's Freestyle private network. They do not expose
the cmux-tui daemon or browser ports to the public Internet.

Userspace WireGuard is the only way cmux reaches that network. `cmux-wg`
combines BoringTun for WireGuard with smoltcp for TCP, so no system interface,
route, or macOS VPN approval is involved. cmux ships no Network Extension and no
`cmux vpn` command.

| traffic | path | first user action |
| --- | --- | --- |
| cmux-tui terminals and agent metadata | SOCKS5 through the app's userspace WireGuard hub | none |
| browser tabs on a VM's localhost, and Desktop | the app's loopback proxy, then the same hub | none |
| `ssh NAME` to an enrolled machine | `cmux wg dial` as the ssh ProxyCommand, through the hub | `cmux cloud enroll-machine` |
| any other Mac app reaching a VM private IP | not available (see [Other apps on this Mac](#other-apps-on-this-mac)) | none |

Browser and Desktop show inline connection errors with a Reload action. They
never offer VPN setup.

## Terminal path

```text
cmux terminal pane
  -> bundled cmux-tui sidecar
  -> SOCKS5 over an owner-only Unix socket
  -> one app-owned cmux-tui WireGuard hub
  -> Freestyle private network
  -> VM cmux-tui daemon
```

`CloudTunnelHub` starts `cmux-tui wg hub --config - --socket <path>
--client-token-stdin` (`cmux-remote/src/wireguard_hub.rs`). One app process owns
one hub and shares it across all VM links, because a WireGuard key carries one
live session. Each sidecar runs `remote connect --wireguard-hub <socket>
--wireguard-hub-token-stdin`. It cannot dial the private VM address directly,
and a client without the per-launch hub token reaches only port 22.

The WireGuard key is made per app launch and held only in memory. Each hub
start enrolls its public key through `POST /api/vm/tunnel`, which rotates this
Mac's terminal peer to it, so a rotated or revoked peer heals on the next start.
The completed configuration reaches the hub on stdin and is never written to a
file.

cmux-tui connections need no device invitation and no approval. The VM's
daemon serves a trusted-carrier listener that is reachable only inside the
private network, so the Mac dials `remote connect <route> --carrier` and is
admitted by the network itself. Every connection uses the private route, with
no connection ticket and no Freestyle call.

## Ports and Desktop path

A browser tab in a Cloud workspace sees that machine's localhost
(`plans/cmux-next/remote-localhost.md`). The tab strip and omnibar show the
machine name while the page is a loopback origin. Only literal loopback hosts
(`localhost`, `127.0.0.0/8`, `::1`) go to the machine; every other destination
connects directly from this Mac, and nothing falls back to this Mac's localhost.

```text
Chromium browser store for (profile, machine)
  -> RemoteLocalhostProxy: one 127.0.0.1 listener per machine, peer-process checked
  -> ports: loopback-forward-v1 on the machine's daemon connection (itself over the hub)
  -> Desktop: HubLoopbackOpener, SOCKS5 CONNECT on the hub to the machine's private address
  -> VM
```

Each machine's store is isolated per browser profile and machine. The proxy
accepts a connection only from this app's process or its Chromium helpers, and
only proxy-form requests, so a page cannot use the listener directly.
`HubLoopbackOpener` presents the hub's client token and opens no TCP port on
this Mac. No guest firewall rule, system network route, public preview, or
macOS VPN approval is needed.

Opening a page starts the userspace connection automatically. Loading and failure
states remain in the same browser pane and Reload retries the connection.
Sign-out, machine removal, and process exit close the proxy and the hub.

## Other apps on this Mac

The hub serves only cmux processes. Two paths give other local clients a VM
today:

- `cmux cloud enroll-machine --target machine:<id> --name NAME` writes a
  `Host NAME` block to `~/.ssh/cmux-cloud/config` whose ProxyCommand is
  `cmux wg dial --hub`, and pins the machine's host key. `ssh NAME` then works
  while the app runs.
- `cmux cloud port-forward --target machine:<id> --port N` forwards one VM port
  to `http://127.0.0.1:<local_port>/` on this Mac (machines on the Cloud app
  server link only).

What only a system-wide route would add is any other Mac app reaching a VM
private IP on its own: a browser outside cmux, plain `ssh` to an address that
was not enrolled, `curl`, or HTTPS to a private hostname. That needs an Apple
Network Extension. None ships: one landed on 2026-11-03 and was reverted the
same day (#34198) because it did not compile on the macOS 26.5 SDK. Its re-land
is open as #34204, pending a product decision. Until then the signing scripts
refuse any NetworkExtension entitlement or bundled system extension
(`scripts/sign-cmux-bundle.sh`, `scripts/ci/check-signed-app.sh`,
`scripts/ci/release-signer/sign-app.sh`,
`tests/test_sign_cmux_bundle_tunnel_gate.sh`).

Planned userspace covers for those cases are a `cmux ssh` ProxyCommand that
needs no per-machine enrollment and a "forward port to localhost" action on
every machine link.

## Who holds a WireGuard key today

| owner | where | key |
| --- | --- | --- |
| Cloud hub (terminals, agent metadata, browser ports, Desktop, enrolled ssh) | `CloudTunnelHub.swift` -> `cmux-tui wg hub` (`cmux-remote/src/wireguard_hub.rs`); `RemoteLocalhostProxy.swift`, `HubLoopbackOpener.swift` | per launch, in memory |
| Native link | `NativeDeviceEnrollment.swift` hands its key to `cmux-tui link serve` (`link/mesh.rs`, `WgMesh`) | the device enrollment's key |
| acpmux, Labs only | `acpmux/src/wireguard.rs` | `~/.acpmux/node.wg.key` |
| iOS | `cmux-mobile-link/src/dial/wireguard.rs`, in process | per session |

`cmux-wg-tun` (WireGuard over a macOS utun fd, written for the extension) is a
workspace crate that nothing depends on. It stays unused until the extension
decision is made.

### Planned: one link on the Mac

A WireGuard key carries one live session: two processes holding the same key
steal each other's traffic. The plan is one userspace link on the Mac that holds
the only copy of the key and replaces the three Mac owners above. The hub,
the Native link, and acpmux's transport then dial through it.

## Device identity and revoke

`cloud_vm_access_grants` contains one row for the physical Mac. It stores the
stable Mac ID, reported device name, user-edited display name, model, macOS
version, CPU architecture, cmux version, build, channel, first-seen time,
last-seen time, and revoked time.

`cloud_vm_tunnels` contains every channel's peers under that access grant.
Stable, Nightly, RC, staging, and DEV builds can add their Stack login sessions
to `cloud_vm_access_grant_sessions`, but they still appear as one Mac on
cmux.com. `POST /api/vm/tunnel` still accepts a `browser` tunnel purpose; the
app only enrolls `terminal` peers.

Sign-out stops the hub, drops the in-memory key, and asks the server to revoke
the physical Mac. Remote revoke on cmux.com deletes every Freestyle peer under
the grant and revokes every recorded Stack login session. The server also
stores each login's issue time. A channel that signed in before the physical Mac
revoke cannot make its first peer after the revoke. Signing in again can create
a new access grant. This is account access revoke, not a permanent hardware ban.

The iOS Iroh pairing registry remains separate. It describes phone-to-Mac
discovery and does not grant access to the Freestyle private network.

## Minimum provider and control-plane calls

Normal terminal traffic, terminal metadata, and browser traffic do not pass
through Vercel or Freestyle APIs.

Freestyle calls required by this design are:

1. Create or find the account private network during VM provisioning.
2. Create or rotate one channel's terminal WireGuard peer each time the hub
   starts (`POST /api/vm/tunnel`).
3. Delete that Mac's peers across all channels on sign-out or remote revoke.
4. Create, delete, start, stop, resize, or inspect a VM when the user requests
   that management operation.

The first attach to a machine whose daemon predates the trusted listener costs
one control-plane request that brings the daemon to the pinned build and
restarts it with the trusted drop-in. Nothing is approved and the Mac does not
poll Vercel or Freestyle. Machine list refresh can use the Cloud API, but live
workspace, terminal, pane, display, and agent metadata comes from cmux-tui
through the hub.

## WireGuard implementation

```text
cmux-remote DirectWebSocketProvider
  -> Dialer
     -> OsTcpDialer for non-Cloud routes
     -> WireGuardDialer for one in-process link
     -> SocksDialer for Mac sidecars

cmux-wg
  -> boringtun::noise::Tunn
  -> smoltcp Interface and TCP sockets
  -> one Tokio task for UDP, WireGuard, and TCP

cmux-tui wg hub --config - --socket <Unix socket> --client-token-stdin
  -> one WgNet
  -> SOCKS5 CONNECT for private VM routes (literal IPs inside AllowedIPs only)

cmux-tui wg dial --hub <Unix socket> <host> <port>
  -> one TCP stream on stdin and stdout, for an ssh ProxyCommand
```

The user-space stack applies the MTU from the WireGuard configuration (Freestyle
currently supplies 1200; 1420 when none is set), so its TCP maximum segment
size stays within the tunnel packet size.

## Verification

- `cargo test -p cmux-wg`: configuration parsing, handshake, TCP echo, larger
  payloads, and peer restart.
- `cargo test -p cmux-remote`: injected WireGuard dialer, hub SOCKS path, and
  hub control (`wireguard_hub_e2e`, `wireguard_hub_control_e2e`).
- `cargo test -p cmux-tui`: hub command and required capability.
- `CloudHubLoopbackTests`: Desktop's SOCKS5 open through the hub with its
  client token, refusals, and the open deadline.
- `tests/test_sign_cmux_bundle_tunnel_gate.sh`: signing refuses NetworkExtension
  entitlements and a bundled system extension.
- Web tests: one physical Mac, multiple Stack sessions, rename, sign-out revoke,
  remote revoke, and no iOS registry coupling.
