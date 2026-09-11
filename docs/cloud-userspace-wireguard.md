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
| terminal | cmux-tui terminal and metadata; Ports and Desktop panes | user-space WireGuard hub | none |
| browser | a system-wide route for other apps on this Mac (`cmux vpn up`) | Apple Network Extension | allow the cmux network extension |

The terminal role does not create a system interface. It does not run
`wg-quick`, ask for administrator access, or ask for a password. Ports and
Desktop rows ride the same hub: the app opens a loopback listener per machine
port and relays each connection through the hub's SOCKS5 socket, so a pane
loads `http://127.0.0.1:<local port>` on every build without a VPN. The
browser role starts only on an explicit `cmux vpn up`; nothing the app opens
asks macOS to load the extension. There is no public, SSH, or command-line
tunnel fallback.

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

## Ports and Desktop path

```text
cmux browser pane (http://127.0.0.1:<local port>)
  -> app-owned loopback listener for <machine, port>
  -> SOCKS5 CONNECT <private address>:<port> over the hub's Unix socket
  -> the same terminal-role WireGuard hub
  -> VM service (dev server, noVNC on 6901, ...)
```

`CloudHubPortForwarder` keeps one listener per machine port for as long as the
machine is in the fleet; an idle listener holds no hub lease, and each accepted
connection claims the hub for exactly its lifetime. The Ports row's "Copy Link"
hands out the loopback URL, which works in any app on the Mac while cmux runs;
"Copy Private Address URL" gives the raw `http://<private ip>:<port>` for a Mac
with its own route (`cmux vpn up`). A machine without a private address falls
back to the control plane's tokened preview URL.

## System-wide route (`cmux vpn up`)

`cmux vpn up` creates a separate browser peer through `POST /api/vm/tunnel`,
saves its configuration in the Apple VPN manager, and requests activation of
the bundled packet tunnel system extension. macOS can require one user
approval in System Settings › General › Login Items & Extensions; the CLI
explains what is about to be installed before the request, and the Machines
panel shows the wait with a button to that pane. cmux must not request this at
launch, during machine list refresh, during terminal use, or when a Ports or
Desktop row is opened.

After approval, macOS starts the route without `sudo` or a password. Later
`cmux vpn up` runs reuse the saved peer and VPN configuration. This route is
for other apps on the Mac (a system browser, `ssh`, `.internal` hostnames via
`cmux vpn hosts`); cmux's own panes never depend on it.

### Activation gate

Nothing on the browser path runs until `CloudActivationPolicy` admits it. The
policy is built once at the composition root from local state only, and it is
the single decision every tunnel consumer (browser navigation, `cmux vpn up`,
`vm.tunnel_config`, `vm.tunnel_up`) flows through:

- A start is admitted only when `Settings › Beta Features › Cloud Machines` is
  on (`cloud.beta.machines.enabled`, off by default on every build, and never
  forced on by a managed `DisableCloud` profile) **and** the account has at
  least one machine. Launch-time decisions and status answer "has a machine"
  from a cached marker written by every machine list and create
  (`cloud.machines.cachedHasAny`; cleared on sign-out, reset to unknown by a
  delete). An explicit start (`cmux vpn up`, a Cloud browser open) does not
  trust that marker: it settles the count against the control plane with one
  fleet list before scheduling the start, so a machine deleted or created
  outside this app is neither trusted nor missed; while the tunnel is up or a
  start is in flight, uses read local state only. A refused start touches
  neither enrollment nor NetworkExtension and reports `cloud-machines-off`
  or `no-cloud-machine` (`start_refusal` in `vm.tunnel_status`, from local
  state only).
- The NetworkExtension controller, whose construction reads
  `NETunnelProviderManager` preferences, is built at launch only when the
  browser-role config already exists on this Mac (a previous opted-in session
  saved a VPN configuration), so an inherited tunnel can still be adopted or
  stopped. Otherwise it is built on the first admitted start. A fresh install,
  or an update from a version without the tunnel, therefore never calls
  NetworkExtension at all.
- The Beta Features toggle is honored while the app runs: turning it off
  brings a running tunnel down; turning it on lets the next Cloud use start
  the tunnel without a relaunch. The periodic fleet read (`GET /api/vm` from
  the cmux-tui registry) runs only while the toggle is on **or** this Mac has
  used Cloud before (the marker said the account had a machine, or a tunnel
  role was enrolled here), so an idle app that never opted in makes no Cloud
  API traffic, while an existing Cloud user's fleet keeps reconnecting even
  with the toggle off. Sign-out clears that evidence and stops the poll; a
  delete resets the marker to unknown until the next list.
- `down`, `revoke`, sign-out, and quit stay available regardless, so a tunnel
  from an earlier opted-in session is always cleaned up.

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
2. Create one channel's terminal WireGuard peer on its first terminal, Ports,
   or Desktop use.
3. Create one channel's browser WireGuard peer on the first `cmux vpn up`.
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
- Tagged Mac build: system VPN off, two VM terminals work through one hub, a
  Ports row opens `http://127.0.0.1:<port>` through the same hub, no new
  system interface, and no password prompt.
- `CloudLoopbackPortForwardTests`: a loopback client, the real forward, and a
  fake SOCKS5 hub; bytes relay both ways, a refused CONNECT closes the client,
  the hub lease follows each connection, and one machine port keeps one local
  port across a private-address change.
- Signed Nightly build: opening a Ports or Desktop row never asks for Network
  Extension approval; `cmux vpn up` does, the Machines panel shows the wait
  with an Open System Settings button, and revoke ends both paths.
