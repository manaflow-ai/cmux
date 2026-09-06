# Cloud private network access

Cloud VMs live in the account's Freestyle private network. They do not expose
the cmux-tui daemon or browser ports to the public Internet.

cmux uses two WireGuard role types for one physical Mac. One app channel uses
at most one peer for each role. Stable and Nightly use separate peers because
they can run at the same time, but all peers belong to one access grant. The
access grant is the single Mac shown on cmux.com. A CUA helper does not create
a peer unless it later becomes a direct Cloud network client.

| role | traffic | implementation | first user action |
| --- | --- | --- | --- |
| terminal | cmux-tui terminal and metadata | user-space WireGuard hub | none |
| browser | browser and webview traffic to private VM addresses | Apple Network Extension | allow the cmux network extension |

The terminal role does not create a system interface. It does not run
`wg-quick`, ask for administrator access, or ask for a password. The browser
role starts only when the user opens a Cloud browser or webview. A browser
does not navigate to a private address until the Network Extension is ready.
There is no public, SSH, or command-line tunnel fallback.

## Terminal path

```text
cmux terminal pane
  -> bundled cmux-tui sidecar
  -> SOCKS5 over an owner-only Unix socket
  -> one app-owned cmux-tui WireGuard hub
  -> Freestyle private network
  -> VM cmux-tui daemon
```

The hub uses `cmux-wg`, which combines BoringTun for WireGuard with smoltcp for
TCP. One app process owns one terminal peer and shares it across all VM links.
Each sidecar receives `--wireguard-hub <socket>`. It cannot dial the private VM
address directly.

The first terminal use creates the terminal peer through `POST /api/vm/tunnel`.
The completed WireGuard configuration stays on the Mac with mode 0600. Later
app launches reuse it and make no Freestyle tunnel call.

cmux-tui connections need no device invitation and no approval. The VM's
daemon serves a trusted-carrier listener that is reachable only inside the
private network, so the Mac dials `remote connect <route> --carrier` and is
admitted by the network itself. Every connection uses the private route, with
no connection ticket and no Freestyle call.

## Browser path

The first Cloud browser use creates a separate browser peer through
`POST /api/vm/tunnel`, saves its configuration in the Apple VPN manager, and
requests activation of the bundled packet tunnel system extension. macOS can
require one user approval in System Settings. cmux must not request this at
launch, during machine list refresh, or during terminal use.

After approval, macOS starts the browser route without `sudo` or a password.
Later browser opens reuse the saved peer and VPN configuration. Private IP
addresses can stay visible in browser URLs.

## Device identity and revoke

`cloud_vm_access_grants` contains one row for the physical Mac. It stores the
stable Mac ID, reported device name, user-edited display name, model, macOS
version, CPU architecture, cmux version, build, channel, first-seen time,
last-seen time, and revoked time.

`cloud_vm_tunnels` contains every channel's terminal and browser peers under
that access grant. Stable, Nightly, RC, staging, and DEV builds can add their
Stack login sessions to `cloud_vm_access_grant_sessions`, but they still appear
as one Mac on cmux.com.

Sign-out deletes both local role keys and stops both routes. It also asks the
server to revoke the physical Mac. Remote revoke on cmux.com deletes every
Freestyle peer under the grant and revokes every recorded Stack login session.
The server also stores each login's issue time. A channel that signed in before
the physical Mac revoke cannot make its first peer after the revoke. Signing in
again can create a new access grant. This is account access revoke, not a
permanent hardware ban.

The iOS Iroh pairing registry remains separate. It describes phone-to-Mac
discovery and does not grant access to the Freestyle private network.

## Minimum provider and control-plane calls

Normal terminal traffic, terminal metadata, and browser traffic do not pass
through Vercel or Freestyle APIs.

Freestyle calls required by this design are:

1. Create or find the account private network during VM provisioning.
2. Create one channel's terminal WireGuard peer on its first terminal use.
3. Create one channel's browser WireGuard peer on its first browser use.
4. Delete that Mac's peers across all channels on sign-out or remote revoke.
5. Create, delete, start, stop, resize, or inspect a VM when the user requests
   that management operation.

The first attach to a machine whose daemon predates the trusted listener costs
one control-plane request that brings the daemon to the pinned build and
restarts it with the trusted drop-in. Nothing is approved and the Mac does not
poll Vercel or Freestyle. Machine list refresh can use the Cloud API, but live
workspace, terminal, pane, display, and agent metadata comes from cmux-tui
through the terminal WireGuard link.

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

cmux-tui wg hub --config <WireGuard configuration> --socket <Unix socket>
  -> one WgNet
  -> SOCKS5 CONNECT for private VM routes
```

Freestyle currently supplies MTU 1200. The user-space stack applies that MTU,
so its TCP maximum segment size stays within the tunnel packet size.

## Verification

- `cargo test -p cmux-wg`: configuration parsing, handshake, TCP echo, larger
  payloads, and peer restart.
- `cargo test -p cmux-remote`: injected WireGuard dialer and hub SOCKS path.
- `cargo test -p cmux-tui`: hub command and required capability.
- Web tests: one physical Mac with two role peers, multiple Stack sessions,
  rename, sign-out revoke, remote revoke, and no iOS registry coupling.
- Tagged Mac build: system VPN off, two VM terminals work through one hub, no
  new system interface, and no password prompt.
- Signed Nightly build: the first Cloud browser asks for Network Extension
  approval, terminal-only use does not ask, and revoke ends both paths.
