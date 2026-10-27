# cmux next: how a browser pane reaches a port in a workspace (design)

User request (2026-10-21, Lawrence): a workspace whose left pane is a terminal
running tmux with a web server in it, and whose right pane is a Chromium
browser connected to that server through a proxy, "designed well from first
principles, some WireGuard stuff too". The same workspace is the repro bench
for sizing bugs (section 9).

Status (2026-10-21): the demo runs on a Mac mini over Tailscale and on a
Freestyle VM with the browser on Lawrence's Mac (section 8); `terminal-ports`
is built (section 6). Section 5.1 (Rust and CEF fork split) and section 7 are
design.

Labels: **FACT** has a source in this repo or a measurement given here;
**GUESS** is not verified.

## 1. The problem in one sentence

A page in a browser pane must reach `localhost:PORT` *of the machine where the
pane's workspace runs its terminals* (this Mac, an SSH host, a Cloud VM, a Mac
mini), never another machine's loopback by mistake, with no setup, and the
right port must be found without the person typing it.

Five sub-problems: **route** (which machine), **carrier** (how bytes get
there), **auth and isolation** (who may use the route), **discovery** (which
port), **lifecycle** (reconnects, sharing).

## 2. What already exists (do not rebuild it)

| Piece | What it does | Where |
| --- | --- | --- |
| `loopback-forward-v1` | multiplexed TCP streams to the daemon's own loopback over the authenticated control connection; credit flow control; loopback-only targets checked again on the daemon; 128 streams per connection; audit ring | `cmux-tui/crates/cmux-tui-core/src/server/loopback_forward.rs`, remote-localhost.md 4 |
| In-app proxy | one 127.0.0.1 listener per machine, peer-process authenticated (only the app and its Chromium helpers), CONNECT and absolute-form HTTP, refuses origin-form, so a page cannot use it | `CmuxNextRemoteLocalhost`, remote-localhost.md 5 |
| Derived store | Chromium request context per (browser profile x machine) with `fixed_servers` proxy and `<-loopback>` | remote-localhost.md 3 |
| Route decision | `RemoteLocalhostService.route(for:engine:)`: a tab of a daemon whose `machineID != "local"` gets `.machine(name)` | `CmuxNextRemoteLocalhostService/RemoteLocalhostService.swift` |
| Userspace WireGuard hub | boringtun, one tunnel per key, SOCKS5 CONNECT on an owner-only Unix socket, literal IP targets inside the tunnel's routes | `cmux-tui/crates/cmux-remote/src/wireguard_hub.rs`, browser-egress.md 3.1 |
| Machine port inventory | `machine-listening-tcp` (ss / netstat text) | `cmd_server.rs` |
| `cmux remote forward` | forward a workspace TCP service to a local port (CLI) | `cmux help start` |

FACT (measured 2026-10-21 in the demo, section 8): a Chromium tab of a
workspace in the Chief's session (`cmux-chief-2e448bc2`, a second local
daemon) reaches the dev server through this path. The server sees the TCP
connection opened by the session daemon (`cmux`, pid 19566), not by a
Chromium helper. So the proxy route works today for any non-home session,
the same code path a Cloud VM or SSH host uses, minus the carrier.

## 3. Machines and carriers

| Machine | Control connection the app already has | Carrier for page bytes |
| --- | --- | --- |
| This Mac, home session | none needed | direct (route `.thisMac`) |
| This Mac, other session (Chief, dev builds) | local Unix socket | `loopback-forward-v1` over it |
| SSH host | `cmux-tui remote connect ssh://` local socket | the same channel, over SSH |
| Cloud VM | Cloud link (v12, bulk lane) | the same channel, bulk lane |
| Mac mini on the tailnet | SSH over Tailscale, or the remote entry | the same channel |

The rule that falls out: **the carrier is whatever already carries the
terminal**. A browser page never needs a second network path to the machine,
because the terminal's path is authenticated, reconnecting and already
monitored.

## 4. Options, from first principles

| Option | Auth | Isolation per workspace | DNS rebinding / wrong-machine | Setup | Latency | Reconnect | Sharing |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A. SSH `-L` / `cmux remote forward` to a local port | SSH | none: the local port is open to every local process and every browser profile; ports collide across workspaces | the page is on this Mac's `localhost:N`, indistinguishable from this Mac's own services | a forward per port | 1 hop | the forward dies with SSH; ports change | no |
| B. Per-workspace userspace WireGuard netstack (wireguard-go / boringtun + smoltcp, or tsnet) giving each workspace an address, browser via SOCKS5 into it | WireGuard keys | strong (one netstack per workspace) | needs the same literal-loopback rule; the browser still needs a proxy hop (Chromium has no netstack hook) | key minting per workspace; tsnet = one tailnet node per workspace (ACL churn, Tailscale account, ~30 MB Go runtime per node, GUESS) | +1 encryption layer over a link that is already encrypted | WireGuard roams well | good on paper, but each peer needs keys and routes |
| C. HTTP CONNECT/SOCKS proxy per browser store, carried by the daemon channel (what exists, section 2) | the daemon connection's auth; peer-process check on the local listener | one store per (profile x machine); a page cannot pick the machine | literal-loopback rule on both ends; DNS never resolved; refuses a public name that resolves to this Mac's loopback | none | 1 local hop + the existing carrier | the next request reconnects; open streams fail with a 502 that names the machine; never falls back to this Mac | through the daemon's own sharing (section 7) |
| D. Tailscale Serve / Funnel on the remote | Tailscale identity | per node, not per workspace | a real hostname, so cookies and CORS differ from localhost; dev servers that check `Host` refuse it | needs Tailscale on the remote and an admin-approved serve config | 1-2 hops | good | yes, per tailnet ACL |

Why not B as the browser path: a browser cannot enter a netstack without a
proxy, so B is C plus a second encrypted tunnel inside a link (Unix socket,
SSH, Cloud link) that is already authenticated and encrypted. It adds key
management and a per-workspace network identity for no new guarantee.
System WireGuard (utun) is worse: it needs root and puts routes in front of
every app on the Mac.

Where WireGuard *does* belong: as a **carrier** when there is no control
connection yet or the existing one is the bottleneck. Two real cases:
(1) browser egress through a cmux exit (browser-egress.md 3.1, already
designed on the boringtun hub); (2) direct peer-to-peer between two people's
Macs for a shared workspace, where routing every page byte through the Cloud
relay would cost latency and money (section 7). Both reuse the one hub in
`cmux-remote`; neither needs a netstack per workspace.

## 5. Recommendation

**C, the existing `loopback-forward-v1` + per-store proxy, is the workspace
proxy.** Add to it, in order:

1. **Port discovery** (section 6, built: daemon command `terminal-ports`).
2. **"Open in browser" from discovery**: a new port in a workspace offers a
   chip on the terminal tab ("5173 · Open"); opening it splits right with a
   Chromium tab on the printed URL in the workspace's store. Default: the
   chip only, no auto-open.
3. **Per-workspace store, not only per machine**: today the store key is
   (profile x machine). Two workspaces on one machine share `localhost:3000`
   cookies. Key it (profile x machine x workspace) when the workspace sets
   `browser.isolateLocalhost` (default: off, matches current behavior).
4. **Move the proxy hop into the CEF fork and the daemon** (section 5.1).
5. **WireGuard carrier** for sharing (section 7), later, behind the same
   `LoopbackOpener` interface, so the browser side does not change.

### 5.1 Where each part lives: Rust, the CEF fork, Swift

User decision (2026-10-21): "most probably via rust and CEF fork"; Swift is
for UI only.

| Part | Today | Target | Why |
| --- | --- | --- | --- |
| Loopback streams on the machine (`loopback-forward-v1`: loopback-only check, credit flow, audit) | Rust, cmux-tui daemon | unchanged | the daemon is the only process on the machine; Linux VMs, SSH hosts and Mac minis run it |
| Port discovery (`terminal-ports`) | Rust, daemon (built here) | unchanged | it reads the PTY the daemon holds; same code on macOS and Linux |
| Route decision (which machine a tab's localhost is) | Swift `RemoteLocalhostService.route` | Rust: the daemon answers "route for browser tab T" from its own workspace/session records (`machineID != local`, `browser.remoteLocalhost*`, capability) | one rule for the Mac app, cmux-tui, iOS and the Linux browser host; a page or the app's view state cannot change it |
| Local proxy listener (CONNECT + absolute-form HTTP, peer-process auth, 502 page, rebinding guard) | Swift `RemoteLocalhostProxy` + `ProxyConnection` in the app process | the CEF fork: a `URLLoaderFactory` / network-service interceptor for the derived store that hands each loopback request to a Rust stream client (a C ABI from a small Rust static library linked into the shim) | removes the 127.0.0.1 listener and its peer-process check (remote-localhost.md 5 names it as the follow-up); no app-process byte copy; WebSocket and HTTP/2 stay byte streams |
| Stream client (one daemon connection per machine, base64 frames, credit) | Swift `LoopbackForwardClient` | Rust, the same crate the daemon's tests use (`cmux-sdk` client side) | the wire format is defined in Rust; one implementation, tested on Linux |
| Per-profile store with proxy settings | CEF shim `shim_proxy.mm` (context proxy, navigation guard) | CEF fork: the derived store's network context created with the interceptor before its first request (closes remote-localhost.md 9 open item 1) | the first request of a new store can never go direct |
| Machine chip, "Open" chip, 502 page text, settings UI | Swift | Swift | UI |

Order: (a) the route decision in Rust first (smallest, no fork change);
(b) the stream client in Rust behind the current Swift proxy (`LoopbackOpener`
is already an interface); (c) the fork interceptor replaces the listener.
Each step keeps `RemoteLocalhostLiveTests` green.

WebKit stays as remote-localhost.md 7 says: Network.framework never sends
loopback destinations to a per-store proxy, so WebKit tabs cannot use a
machine's localhost.

## 6. Port discovery: `terminal-ports` (built)

The obvious design walks the terminal's process tree, follows a tmux client
to its server's panes (a tmux server daemonizes, so a dev server in a tmux
pane is **not** a descendant of the terminal), and reads each process's
sockets. The prototype did that (`ports.py`, `macsockets.py`: libproc on
macOS, `/proc` on Linux, 0.2 s). **It is not allowed in product code**:
cmux-next never scans processes (plans/cmux-next/pty-holder.md 4; the
push gate `check-no-process-scan.py` refused it), and the plan there removes
even the existing tree walk of `terminal-resources`.

The built design uses only what the rule allows, the PTY the daemon holds
and a socket connect:

1. Read the terminal's text: the active screen with its scrollback, the last
   1 MiB. A server prints where it listens (`Local: http://localhost:5173/`,
   `Serving HTTP on 0.0.0.0 port 8000`). tmux draws its panes into the
   client's PTY, so a URL printed in a tmux pane is in this text too while the
   pane shows it.
2. Keep addresses on `localhost`, `127.x.y.z`, `0.0.0.0`, `[::1]`, `[::]`,
   `*` with a port; newest mention first, each port once, at most 32. A LAN
   address is not a loopback route and is skipped.
3. Connect to 127.0.0.1, then ::1, 150 ms each. Report the ports that accept
   (`listeners: [{port, host, url, bound}]`) and the ones that refused
   (`closed`).

Daemon command `terminal-ports {surface}`, capability `terminal-ports-v1`,
spec in `cmux-tui/spec/commands.md`, SDKs regenerated. Code:
`cmux-tui/crates/cmux-tui-core/src/server/terminal_ports.rs`.

Limits, and the next step for each:

| Limit | Next |
| --- | --- |
| A server that prints nothing (or whose line scrolled out of a tmux pane, which keeps its own scrollback) is not found | OSC 7501 `kind=server port=N`: a dev server or a shell hook reports itself (hooks and OSC 7501 are how cmux-next learns about programs) |
| A port another program on the machine owns can be named in the text and accept | the route only reaches loopback of the same machine, which the workspace's user owns; the chip shows the URL before anything opens |
| Polling | none: clients ask when the terminal's output settles (`terminal-events`), not on a timer |

Pick rule for "the" port when several accept (`demo.py pick_port`): the
newest mention, then known dev ports (5173, 3000, 8000, 8080, ...).

## 7. Reconnects, sharing, multiplayer

- **Reconnect**: unchanged from remote-localhost.md 5: a dropped daemon
  connection fails open streams, the browser shows a 502 page naming the
  machine, the next request reconnects. Live-reload pages reconnect their SSE
  or WebSocket by themselves (the demo's page shows "reconnecting").
- **Sharing** a workspace with a teammate: the teammate's app reaches the
  workspace's daemon through the same remote entry it uses for terminals
  (`cmux link` peers, policy-gated); the page bytes ride that link. The owner
  decides per workspace whether shared viewers may open loopback streams
  (default: no; terminals can be shared without exposing dev servers).
- **WireGuard carrier for sharing**: when two Macs share a workspace and
  both can reach each other (same tailnet, or a NAT-punched UDP path), the
  Cloud relay hands them a short-lived WireGuard key pair for the boringtun
  hub, and `loopback-forward-v1` streams run over that tunnel to the owner's
  daemon instead of through the relay. Same auth decision as above, same
  daemon-side loopback-only rule. Not built.

## 8. The demo on two remote machines (built, 2026-10-21)

The browser is a Chromium tab in the app on Lawrence's Mac; tmux and the dev
server run on the remote machine; the tab reaches the server through
`loopback-forward-v1`. Proof: the dev server's `/hop` names the process that
opened the TCP connection (libproc on macOS, `/proc` on Linux), and the page
shows it.

| Case | Machine | Session daemon | How the app reaches it | Page shows |
| --- | --- | --- | --- | --- |
| Mac mini over Tailscale | cmux-lawrence (macOS 26.5, arm64) | `cmux-tui-nightly-eeb26d8 --headless --session proxy-demo-mini` (the app's own cmux-tui build, copied next to the existing one) | app action `remote.connect` (SSH over the tailnet, `--binary` that path) | "through the workspace proxy: opened by cmux-tui-nightly-eeb26d8:75986" |
| Freestyle VM | cmux Cloud machine proud-lilac-cobra (Ubuntu 24.04, x86_64) | `~/.cmux/bin/cmux-tui server start --session cloud` swapped to a current Linux build (CI artifact of d628b798f02; the image's 0.1.0 a9b104f had no `loopback-forward-v1`, so the tab would have shown this Mac's localhost) | the Cloud link | "through the workspace proxy: opened by cmux-tui:30510" |

What it took, and what should change:

- The Cloud VM image ships a cmux-tui without `loopback-forward-v1`
  (0.1.0 a9b104f). The image must carry a current cmux-tui; until then every
  Cloud browser tab shows "localhost = this Mac" (remote-localhost.md 6).
- The VM's SSH address (10.16.x) is not reachable from the Mac; files moved
  through `cmux cloud file-write` in 700 KB chunks (50 chunks for 26 MB).
  A `cloud file-put --path` that streams a local file would make this one
  call.
- The CLI cannot address a remote session's panes from the Mac
  (`selector.not_found`; `--machine` lists only `local`), so the workspace,
  split and browser tab were created by running the remote cmux-tui on the
  machine (over SSH or `cloud exec`). The app rendered them.
- Scripts: `scripts/cmux-next/proxy-demo/` (`tmux-up.sh`, `devserver.py`,
  `ports.py`, `macsockets.py`, `linuxsockets.py`, `sizebench.py`, `demo.py`
  for a local session; 16 tests: `python3 -I scripts/cmux-next/proxy-demo/test_proxy_demo.py`).

## 9. Sizing bench

Three layers must agree after every resize: the daemon's terminal grid, the
inner tmux client, and the tmux panes. `sizebench.py` runs a real cmux client
(`cmux attach --terminal`, `--cmux` names the binary) inside a harness tmux
of known size and resizes it. Times are until all layers agreed.

| Case | This Mac, Chief session (load 140) | Mac mini | Freestyle VM |
| --- | --- | --- | --- |
| attach 120x40 | ok, 40 ms | ok, 224 ms | ok, 210 ms |
| grow 200x60 | ok, 200 ms | ok, 15 ms | ok, 17 ms |
| shrink 80x24 | ok, 125 ms | ok, 314 ms | ok, 271 ms |
| tiny 20x6 | ok, 330 ms | ok, 248 ms | ok, 278 ms |
| wide 300x20 | ok, 150 ms | ok, 253 ms | ok, 281 ms |
| drag storm, 40 sizes in 1 s | ok, 140 ms | ok, 132 ms | ok, 203 ms |
| back to 120x40 | ok, 250 ms | ok, 187 ms | ok, 267 ms |

The bench's client runs on the machine itself. The app's own sizing over the
link (split drag, window resize, zoom, the browser view frame) needs the app
on screen, which an agent cannot drive on Lawrence's Mac
(`pane.screenshot`: "Only a person in cmux can run this action").

Found and fixed:

- Demo: tmux takes rows from the last pane on a shrink, so the monitor pane
  collapsed to 1 row (`client-resized` fires before the window resizes;
  a `window-resized` window hook works). The monitor read the active pane,
  not its own (`-t $TMUX_PANE`). The harness tmux server does not inherit the
  caller's PATH, so the first mini run attached an old `cmux` (`--cmux`).
- App: a Chromium tab created in a pane that was not on screen started at
  `hiddenTabViewport` 1280x800 whatever the pane's size, so a responsive page
  laid out for desktop and reflowed when shown (the demo tabs read 1280x799).
  Now `CEFHostView` reports each on-screen frame and `CEFPaneHost` starts a
  new tab at its pane's last size; a pane never shown still starts at
  1280x800 (`CEFPaneHostCreationSizeTests`).
