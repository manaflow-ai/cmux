# Remote browser tabs on a cloud machine

Status: design for the first slice, 2026-11-21. Lane `lane/remote-browser-vm`.

Leo, 2026-11-21: "99 if not 100% of what I need from Cosmic Gray is essentially just some sort of interface to
talk to you guys and then to browse the f***ing web. ... we have VMs, right? Like the VMs, the whole point is
that, well, we can also potentially browse the web, offload our s***, our f***ing web browsing, our f***ing RAM
usage, our CPU usage, all of that onto the VMs themselves. That's the feature"

Goal: a browser tab in a cmux NEXT pane whose Chromium runs on a cloud machine. The Mac pays for H.264 decode
and present only.

## What exists

Almost the whole path is built. One piece is missing: the host does not run on Linux.

| Piece | Where | State |
|---|---|---|
| rb/1 protocol and pure reducers (session, menus, input mapping) | `cmux-tui/crates/cmux-remote-browser` | built, platform-neutral |
| Host core: viewer control and input in, calls on a `Presentation` out | `cmux-remote-browser-host/src/tab.rs:20` (`trait Presentation`), `HostTab` | built, platform-neutral, tested on Linux |
| Pump, admission, lifeline, secret | `pump.rs`, `launch.rs`, `handshake.rs` | built, platform-neutral |
| `--serve` loop | `serve.rs` (CEF UI thread, IOSurface, VideoToolbox) | **macOS only** (`lib.rs:27-31`) |
| `Presentation` backend | `ffi.rs` plus `csrc/rb_shim.mm`, the CEF fork's `cmux_rp_*` | **macOS only**. The fork has no Linux release |
| Linux entry point | `main.rs:229-240` | prints "the macOS host is the only host in r2 (Linux follows)" and exits 2 |
| Daemon route: start a host on the daemon's machine | `cmux-tui-core/src/server/browser_runtime.rs` (`browser-runtime-v1`); spec `cmux-tui/spec/commands.md` "Browser runtimes" | built; installs from `~/.local/share/cmux-tui/browser-host/current/cmux-remote-browser-host` on Linux |
| Mac reaches the host's loopback port | `loopback-forward-v1` on the same daemon link (`CmuxNextDaemon/Loopback/LoopbackForwardClient.swift`) | built |
| Mac picks a machine for a browser tab | `CmuxNextApp/RemoteView/MachineBrowserHosts.swift` (`available(_:)`, DEBUG only, "slice 2 D"), `MachineBrowserPages.swift`, `MachineBrowserPageTab.swift` | built behind DEBUG |
| Cloud machines as daemons | `CmuxNextApp/Cloud/MachineRegistry.swift:82` (`daemon(machine:)` covers Cloud), `CloudMachineSession.swift` (app link `carrier serve`) | built |

So "open this tab on my VM" already works end to end in a DEBUG build against a machine whose daemon has a
browser host installed, and no Linux machine can have one.

## Design

### Where Chromium runs

On the cloud machine: Chrome for Testing's `chrome-headless-shell` (the same engine CI pins in
`scripts/ci/ensure-system-chrome.sh`), or any Chromium named by `CMUX_RB_CHROMIUM`. The host drives it over the
DevTools protocol on `--remote-debugging-pipe` (file descriptors 3 and 4, NUL-delimited JSON): no debugging port
opens, not even on loopback.

`cmux-remote-browser-host` gets a second `Presentation` backend, `CdpPresentation` (`src/cdp.rs`), next to the
CEF shim. `HostTab`, the pump, admission, rb/1 and the Mac viewer do not change. On Linux, `--serve` runs a
loop of its own (`src/cdp_serve.rs`) with the same command line and the same launch contract as the macOS one,
so `browser-runtime-start` starts it unchanged:

- frames: `Page.startScreencast` (JPEG) -> decode -> I420 -> OpenH264 (Cisco's library, loaded with the pinned
  SHA-256, as `cmux-rd` does on Linux) or VAAPI where the machine has a GPU -> rd engine -> datagrams;
- input: rb input -> `HostTab` -> `RpCall` -> `Input.dispatchMouseEvent`, `Input.dispatchKeyEvent` (with
  `commands` for edit commands), `Input.insertText`, `Input.imeSetComposition`;
- page facts: `Page.frameNavigated`, `Page.loadEventFired`, `Target.targetInfoChanged` -> `rb.page`;
- history: `Page.getNavigationHistory` and `Page.navigateToHistoryEntry`, `Page.reload`, `Page.stopLoading`;
- find: `window.find` through `Runtime.evaluate` (no match count in the first slice).

Why not the CEF fork on Linux: it has no Linux release, its remote presentation hands out IOSurfaces, and a
fork build is weeks. Headless Chromium is already installed and exercised on Linux by `cmux-browser-host`.
The CEF path stays the Mac host and can come to Linux later behind the same trait.

### How the machine is chosen and started

The existing placement: `MachineBrowserHosts.available(machine)` says yes when the machine's daemon has
`browser-runtime-v1` and `browser-runtime-status` reports an installed host. Cloud machines are already
daemons (`MachineRegistry.daemon(machine:)`), created and woken by the Cloud path. The cloud image
installs the host and `chrome-headless-shell` under `~/.local/share/cmux-tui/browser-host/<version>/` with
`current` pointing at it. A machine that is asleep wakes on link traffic (1.7 s p50, connectivity map).

The "Open on machine" affordance is UI and follows the rulebook: references and three gallery variants first
(not in this slice).

### Transport

`browser-runtime-start` on the machine's daemon -> the host listens on `127.0.0.1:0` and prints
`{"listening":...}` -> the Mac opens a `loopback-open` stream to that port on the same daemon link and speaks
rd/1 (stream carrier) with the per-launch secret as the hello token. For a Cloud machine the link is the app
link (`carrier serve`, relay or direct). No socket listens off the machine.

This is TCP on every hop, so the engine runs with one frame in flight at high RTT (the Cloud desktop's known
limit, connectivity map section 3.3). Next: the same UDP rd-link upgrade the Cloud desktop uses for media.

### Clipboard

- Paste: the viewer sends text; the host types it with `Input.insertText` (one call, no key events).
- Copy: Cmd-C reaches the page as a key with the `copy` edit command; the host then reads the selection
  (`Runtime.evaluate("getSelection().toString()")`) and sends it to the viewer, which writes the Mac
  pasteboard. Needs one rb message; second slice.

### Cookies and profile

One persistent profile per machine, `~/.local/share/cmux-tui/browser-host/profiles/default` on the machine's
disk (`--user-data-dir`). Tabs share it, as a person's browser does. Cloud machines keep their disk across
sleep, so a login survives a sleep and a host restart. Deleting the machine deletes the profile.

### When the machine is unreachable

The remote-cloud-durability rule: a bounded, labelled pause with an action. The pane keeps the last frame,
shows "Machine unreachable" with Reconnect and Open on this Mac. It never opens the page locally on its own: a
local tab has other cookies. The host's lifeline is the daemon link: when the link drops for good, the
daemon ends the runtime; a short drop inside the carrier's resume lease keeps it.

### Budget on Leo's Mac

| | Local Chromium tab | Tab on a machine |
|---|---|---|
| Mac RAM | renderer plus share of GPU and browser processes, 100-400 MB per busy tab | one H.264 decoder and a layer, about 20-40 MB (estimate, to measure) |
| Mac CPU | page JS, layout, raster | hardware decode, under 1 ms per frame |
| Latency added | none | screencast 5-15 ms + JPEG decode and I420 2-6 ms + encode 4-8 ms (1080p, software) + network RTT + decode 1-2 ms |

Target for a nearby region: key to photon under 100 ms (screen-share-under-100ms.md D10 budget, with the
screencast stage in place of capture). Measure with `--probe` against the Linux host before claiming it.

## Slices

1. **This PR.** `CdpPresentation` (pure, tested with a fake pipe), the CDP pipe codec, the Chromium launcher,
   and Linux `--serve` that streams a real page into rb/1, checked by `--probe` style tests on cmux-ci with a
   real headless Chromium.
2. Install the Linux host and `chrome-headless-shell` in the cloud image; a Linux release of the host.
3. Copy to the Mac pasteboard; `rb.page` titles and favicons; find counts.
4. The "Open on machine" affordance (gallery variants first), and lifting `MachineBrowserHosts` out of DEBUG.
5. UDP rd-link for media; VAAPI on GPU machines; one shared host per machine (process-sharing.md).
