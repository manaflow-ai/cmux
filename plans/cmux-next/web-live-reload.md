# Live web reload in a running cmux-next

Goal: web edits on this Mac or in any lane's worktree show up in the running app within seconds,
with no Swift build, no relaunch and no wait on CI. The same edits still go through PRs.

## First version (implemented)

`web-dev.json` next to `cmux-next.json` (`~/.config/cmux/web-dev.json`) is read by Debug builds,
NIGHTLY builds and cmux NEXT DEV (`com.cmuxterm.app.debug.next`, #24046) only
(`WebDevOverride.isAvailable`). Release and RC builds never read it. Debug Settings > Pages > "Live web reload (web-dev.json)" (`PageTunables.webDevOverride`, on
by default) ignores the file while off, without editing it.

```json
{"server": "http://127.0.0.1:4181/", "overlay": "~/Library/Application Support/cmux-next/web-overlay"}
```

- **server**: a Vite server on loopback with an explicit port (`web-overlay.sh server --local`,
  `bun run dev`, `dev-slot.sh`, or a declared remote slot through an ssh tunnel). The React pages, the diff, markdown and editor viewers, and the bundled agent pane
  fetch their files from it, and HMR applies edits in about a second. The page keeps its own origin
  (`cmux-page://<id>`, `cmux-agent://pane`). The scheme handler fetches the file from the server
  and answers under that origin, so the host bridge, the CSP and the trust checks stay the shipped
  ones. The dev server's `appHostServer` plugin points the Vite client's HMR socket at
  `127.0.0.1:<port>`, because the page's origin is not the server's.
- **overlay**: built bundles (`agent-pane/`, `pages/<resource>/`, `webviews-app/`) that replace the
  bundled files. `scripts/cmux-next/web-overlay.sh build|install` copies a build into a new
  generation folder, then swaps a symlink per surface. It writes `manifest.json` last, and the app
  reloads when that file changes.
- **Fallback**: both are read on every request. A request the server cannot answer (connection
  refused, 4xx, 5xx) gets the overlay's file, else the bundled one. A surface whose overlay folder
  lacks its entry keeps the bundle. `web-overlay.sh off` (`"enabled": false`) or deleting the file
  restores the bundled pages on the next reload.
- **Reload**: `WebDevOverrideWatcher` watches the file and the manifest with kernel vnode events,
  no polling. On a change it reloads every web view the page and agent pane scheme handlers have
  served. The first page served starts the watch.

- **Engine**: Chromium serves the bundled folder it was handed at start and never reads the file,
  so while a server or overlay is in force every cmux page opens in WebKit
  (`PageWebKitReason.liveWebOverride`). A page already open in Chromium moves on its next open.

Not covered: Chromium does not read the file itself (the engine rule above keeps pages off it). The agent pane
started with `CMUX_NEXT_AGENT_PANE_DEV_URL`, the Debug launch variable, keeps that server.
`CMUX_NEXT_PAGES_DEV_URL` still works and wins over the file.

### Turning it on (anyone on the team, a Debug or NIGHTLY app)

One command from any cmux checkout on your own Mac:

```sh
scripts/cmux-next/web-overlay.sh server --local            # this checkout
scripts/cmux-next/web-overlay.sh server --local --worktree ~/path/to/lane-worktree
```

It installs the webviews dependencies if needed, generates the string tables, starts the webviews
Vite server on `127.0.0.1:4200` (`--port N` for another), and points `web-dev.json` at it. Open
pages and agent panes reload from it; later edits hot reload. `web-overlay.sh server off` stops the
server and restores the bundled pages; `web-overlay.sh status` shows what runs.

- **A shared slot instead.** Declare it in `web-dev.json` as `"slot": {"host": "<ssh host>",
  "port": N}`, on a fleet host listed in `machines/fleet-registry.json` (a CI mini or the GCP pool),
  never a personal machine. `web-overlay.sh server --slot` tunnels the port to `127.0.0.1:N` (the
  same number, since the Vite client opens its HMR socket on it) and falls back to `--local` when
  the slot does not answer.
- **No dev server: built bundles.** `web-overlay.sh fleet [--ref SHA | --working-tree]` builds the
  app on the fleet (`cmux-ci build cmux --tag web-overlay`, the Linux pool; a pushed ref builds under
  the workspace `web-overlay:$USER`, so a newer request supersedes a queued one) and installs its web bundles as the
  overlay. `web-overlay.sh build` does the same from this checkout's own web build, and
  `install-app APP` takes the bundles of any built cmux app.
- **Back to the shipped pages:** `web-overlay.sh off`, or Debug Settings > Pages > "Live web reload".

### Bundle and app skew

The web code talks to the app over versioned bridges (page ops, the acpmux handshake). A tip-of-branch
page against an older nightly can call an op the app lacks; the page shows its normal error for an
unknown op. Keep the slot or the overlay near the nightly's commit (`CMUXCommit` in the app's
Info.plist) when an op is new, or wait for the next nightly. `manifest.json` records the build commit.

## How other apps do it, and why this one should be steadier

- Electron apps in development load the renderer from a dev server (`loadURL(devServerURL)`, the
  electron-vite pattern) and get HMR. That is what `server` does here.
- Apps that update the UI on their own in production either load the UI from a remote origin
  (Slack, Linear and Notion desktop: the UI is a hosted web app, a reload is an update), or
  download a renderer bundle and swap it at the next reload (the code-push pattern). The usual
  failures are a half-written bundle, a stale HTTP or service-worker cache, and a UI newer than the
  native bridge. Here an install is atomic per surface (a symlink rename, manifest last), every
  response is `no-store`, there is no service worker, and every request falls back to the bundled
  file. Bridge skew is the one risk left (above). The next step is to refuse an overlay whose
  manifest names a bridge version the app does not have.

## Electron-style API shim

The page bridge (`cmuxPage`: request/response ops, streams, page commands; `PageHostBridge`) already
plays the role of Electron's `ipcRenderer.invoke`/`on`. What keeps UI in Swift is native capability,
not the transport. Proposed: a `cmux.native.*` op namespace for the common needs (context and app
menus, open/save panels, clipboard, open URL/reveal in Finder, notifications, window controls, drag
sources), granted per page in the descriptor like the existing native ops (`PageNativeOp`), with a
small typed TS client. Once a surface needs only those, its UI can move into hot-reloadable web code.
Not implemented in the first version.

## Longer term: native changes without a local build

1. **Leo's own channel.** A `nightly-leo` (or per-user) appcast. The fleet builds the Swift app at
   the tip of `feat-cmux-next`, plus any PRs Leo opts in to, on every merge or on demand. It signs
   and notarizes the app, publishes it to that feed, and Sparkle installs it at the next quiet
   moment (`UpdateRelaunchGate` already defers relaunch while terminals run foreground commands).
   Same code path as nightly-next, with a smaller audience and a faster cadence.
2. **Incremental delivery.** Sparkle binary deltas between consecutive builds of that channel keep
   each update small. The web bundles ride on top: the app checks the channel's web manifest and
   installs matching bundles as an overlay between native builds, so a web-only merge never waits
   for a native build.
3. **Dev-only native code without relaunch** stays out of scope. Hot-swapping Swift is fragile.
   Instead, move UI that changes often behind the page bridge and the native op shim above, so
   native builds become rare.
4. **Gates.** The channel build runs the same required checks as nightly. A red tip publishes
   nothing, and the last good build stays installed.
