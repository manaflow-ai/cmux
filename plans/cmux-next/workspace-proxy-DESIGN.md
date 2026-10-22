# cmux next: how a browser pane reaches a port in a workspace (design)

User request (2026-10-21, Lawrence): a workspace whose left pane is a terminal
running tmux with a web server in it, and whose right pane is a Chromium
browser connected to that server through a proxy, "designed well from first
principles, some WireGuard stuff too". The same workspace is the repro bench
for sizing bugs (section 9).

Status: section 8's first piece is built and runs on Lawrence's Mac
(`scripts/cmux-next/proxy-demo/`). Sections 5 to 7 are design.

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

1. **Port discovery** (section 6): the daemon reports which ports a
   terminal's programs listen on, including through tmux.
2. **"Open in browser" from discovery**: a new listener in a workspace
   offers a chip on the terminal tab ("5173 · Open"); opening it splits right
   with a Chromium tab on `http://localhost:PORT/` in the workspace's store.
   Default off for auto-open; the chip is the default.
3. **Per-workspace store, not only per machine**: today the store key is
   (profile x machine). Two workspaces on one machine share `localhost:3000`
   cookies. Key it (profile x machine x workspace) when the workspace sets
   `browser.isolateLocalhost` (default: off, matches current behavior).
4. **WireGuard carrier** for sharing (section 7), later, behind the same
   `LoopbackOpener` interface the proxy already uses
   (`DaemonLoopbackOpener`), so the browser side does not change.

## 6. Port discovery

The chain that matters is not obvious: a tmux server daemonizes, so a
server started in a tmux pane is **not** a descendant of the cmux terminal's
shell. FACT (demo): the dev server's parent is the tmux pane's shell, whose
parent is the tmux server (pid 1's child), not the cmux terminal.

Chain: cmux terminal tty -> the tmux client on that tty -> its session ->
the session's pane pids -> their descendants -> LISTEN sockets. Without tmux:
the terminal's root pid -> descendants. (screen and zellij: same idea, their
own client lookup; not built.)

Reading sockets, measured on a Mac with 3,000 processes at load average 140
(2026-10-21):

| Method | Time | Note |
| --- | --- | --- |
| `lsof -iTCP -sTCP:LISTEN` (also with `-p`) | about 5 s | too slow to poll |
| `netstat -anv -p tcp` | 0.2 s from zsh | prints an **empty** list when the calling process is Python (0 lines vs 1,163) |
| libproc `proc_pidinfo(PROC_PIDLISTFDS)` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` on just the chain's pids | 0.2 s for the whole chain, mostly `ps` | what the prototype uses (`macsockets.py`) |
| Linux: `/proc/<pid>/fd` inodes x `/proc/net/tcp{,6}` (or `ss -ltnp`) | ms | for Cloud VMs and SSH hosts |

The daemon verb (proposed, piece 1): `terminal ports <term>` returns
`[{port, host, pid, command, via: "tmux:<session>"|"tree"}]`, and the
daemon emits `terminal-ports-changed` when the set changes, by polling the
chain every 2 s only while a client subscribes. Pick rule for "the" port
(`demo.py pick_port`): a known dev port first (5173, 3000, 8000, 8080, ...),
skip known non-HTTP ports (9229 inspector, 5037 adb), else the lowest. Only
ports bound to loopback or a wildcard are offered; the route reaches loopback
only (remote-localhost.md 2).

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

## 8. Smallest first piece (built)

`scripts/cmux-next/proxy-demo/`, standard-library Python plus the cmux CLI:

| File | Role |
| --- | --- |
| `demo.py create [--session S]` | creates the workspace: left terminal runs tmux, waits for a port by discovery, splits right, opens a Chromium tab (`--engine cef`) in an extension-free profile "Proxy demo", prints every id as JSON (2 s end to end) |
| `tmux-up.sh` | tmux session: dev server on top, size monitor below (30 %, kept after every resize) |
| `devserver.py` | live reload (SSE), a viewport readout, and `/hop`: names the process that opened the TCP connection, so the page shows "through the workspace proxy: opened by cmux:PID" or "direct, not proxied" |
| `ports.py` | the discovery chain of section 6 (tmux-aware) |
| `macsockets.py` | libproc socket reader |
| `sizebench.py` | the resize bench of section 9 |
| `test_proxy_demo.py` | 15 tests, run with `python3 -I scripts/cmux-next/proxy-demo/test_proxy_demo.py` |

Why a script first: every piece it calls exists in the CLI today; it proves
the route and the discovery chain end to end before a daemon verb is
designed around them.

## 9. Sizing bench

Three layers must agree after every resize: the daemon's terminal grid, the
inner tmux client, and the tmux panes; plus the browser viewport for the
right pane. `sizebench.py` runs a real cmux client (`cmux attach --terminal`)
inside a harness tmux of known size and resizes it.

Results, 2026-10-21, Lawrence's Mac at load average 140:

| Case | Result |
| --- | --- |
| attach 120x40 | ok, 40 ms |
| grow 200x60 | ok, 200 ms |
| shrink 80x24 | ok, 125 ms (failed at first: demo bug, below) |
| tiny 20x6 | ok, 330 ms |
| wide 300x20 | ok, 150 ms |
| drag storm, 40 sizes in 1 s | ok, settled 140 ms after the last |
| back to 120x40 | ok, 250 ms |

Found and fixed (demo, not cmux): tmux takes rows from the last pane on a
shrink, so the monitor pane collapsed to 1 row (`client-resized` fires before
the window resizes; `window-resized` works). The monitor read the active pane,
not its own (`-t $TMUX_PANE`).

Not covered by the bench, and why: the Mac app's view sizing (split drag in
the app, window resize, zoom animation, the browser view frame) needs the
workspace on screen. An agent cannot screenshot or lay out a pane on
Lawrence's screen (`pane.screenshot`: "Only a person in cmux can run this
action"), and showing the workspace would move his focus. Next step: run the
same bench against a fleet-built app on a Mac mini, where the app can be
driven on screen, and read `innerWidth/innerHeight` from the page against
the pane's frame.

Observed, needs a decision: a Chromium tab in a pane that was never shown
loads at `hiddenTabViewport` 1280x800 (`CEFPaneHost.swift`), whatever the
pane's real size, so a responsive page lays out for desktop, then reflows
when shown. Using the pane's last laid-out frame (or the window's split
ratio) when it is known would remove that reflow.
