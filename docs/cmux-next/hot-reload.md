# Change cmux live

cmux's pages (Settings, History, Cloud, the viewers) and the agent chat are React. Edit them in a
cmux checkout and the app you're using right now changes as you save: no build, no relaunch, your
windows, chats and terminals stay where they are. It works in every cmux build, in WebKit and in
Chromium, and it's on by default.

## Start in 30 seconds

```sh
git clone https://github.com/manaflow-ai/cmux && cd cmux      # or any checkout you already have
cmux live start
```

Or, without a terminal: press Cmd-Shift-P, run **Edit cmux Live…** and pick the checkout. The same
button is at the end of Settings > General.

Now edit anything under `webviews/src/` and save. Open pages and chats reload once onto your
code, then every save shows up in about a second, keeping each page's state (React Fast Refresh).

Done for now?

```sh
cmux live stop      # the web UI the app shipped with; your files stay
```

Or run **Stop Editing cmux Live**. `cmux live` runs this checkout's `scripts/cmux-next/web-overlay.sh`
(`start` is `server --local`, `stop` is `server off`, `status` is `status`); the script's other modes
below are for slots, pull requests and built bundles. Agents in cmux learn all of this from the
`cmux-live` skill.

| You want | Do this |
|---|---|
| Your edits live in your app | `cmux live start`, or Cmd-Shift-P > **Edit cmux Live…** |
| Another worktree's edits live | `cmux live start --worktree <path>` |
| A worktree's web UI in one window of your app, the others untouched | `scripts/cmux-next/projection.sh open <worktree> [--test CMD]` ([below](#a-projection-window)) |
| Several versions of one change live side by side, keep the best | `scripts/cmux-next/live-copies.sh start 3 [--from <PR\|branch>]...` ([below](#live-copies-side-by-side)) |
| A pull request's web UI, live | `scripts/cmux-next/web-overlay.sh follow <PR>` (again after each push) |
| Try any pull request the cheapest way | `scripts/cmux-next/try-pr.sh <PR>`: live when it can be, else it names the dev build |
| The web UI of every merge, no checkout | Settings > Updates > Web UI Updates > **Every Merge** |
| Stop your dev server | `cmux live stop`, or **Stop Editing cmux Live** (an installed overlay, if any, still serves) |
| The shipped pages back | `scripts/cmux-next/web-overlay.sh off` (ignores the file; run `server off` first to stop the server) |
| Your Rust edits to the daemon live, terminals kept | `cmux live start --rust [--build-host HOST]` ([below](#the-daemons-rust-live)) |
| What's running | `cmux live status` |
| Turn the feature off | Settings > General > **Live Web Reload**, or `cmux settings set updates.liveWebReload false` |

## On and off

**Live Web Reload** (`updates.liveWebReload` in `~/.config/cmux/cmux-next.json`) is on by default.
On, cmux reads `~/.config/cmux/web-dev.json` and serves what it names; with no such file nothing
changes. Off, cmux ignores the file without touching it. Flip it from Settings > General, or from
any terminal:

```sh
cmux settings get updates.liveWebReload
cmux settings set updates.liveWebReload false     # true to turn it back on
```

Every open page and chat reloads when it changes. There is nothing to enable in Debug Settings.

## What survives an update

Your files live outside the app, so an app update keeps them:

- `~/.config/cmux/web-dev.json`: where pages load from (`server`, `overlay`, `"enabled": false`);
- `~/Library/Application Support/cmux-next/web-overlay`: built bundles you installed, with the
  commit they came from in `manifest.json`;
- `updates.liveWebReload` in `cmux-next.json`.

After an update, the app keeps loading your server or overlay. Build or serve from a tree close to
the app's commit (below): web code much newer than the app can call host ops the app doesn't have yet.

Check which commit your app was built from with
`/usr/libexec/PlistBuddy -c "Print CMUXCommit" "/Applications/cmux NIGHTLY.app/Contents/Info.plist"`
(or your app's path).

## Your checkout, live

Run this on your own Mac from any cmux checkout of `feat-cmux-next`:

```sh
scripts/cmux-next/web-overlay.sh server --local
```

It:

1. installs the webviews dependencies when they're missing (`bun install --frozen-lockfile`);
2. generates the string tables;
3. starts the webviews dev server, detached, on `127.0.0.1:4200` (`--port N` picks another);
4. points `~/.config/cmux/web-dev.json` at it.

Open pages and agent panes reload once from the server. After that, saving a file hot-reloads it
in about a second, with no reload of the page and no relaunch. Run it again from another worktree
(`--worktree <path>`) and it restarts the server there.

Pages and chats in Chromium get your files too: while the file points at a server or an overlay,
Chromium hands every page file to cmux, which answers it the way the WebKit pages are answered
(server, then overlay, then web update, then the bundle) with the server's policy, so the HMR
socket connects. Chromium pages that are already open reload onto your code; nothing moves to
WebKit. (An app older than this change still opens such pages in WebKit, #23986.)

The server listens on loopback only, and the app accepts only a loopback URL in `web-dev.json`.
`web-overlay.sh` also writes a fresh random `token` there on every `server` (the file is 0600).
Each request carries a new random nonce (`X-Cmux-Dev-Nonce`), and the app takes an answer only
when its `X-Cmux-Dev-Proof` is HMAC-SHA256 of that nonce keyed by the token; a webviews dev server
computes it from the same file. The token never crosses the wire, so if your server stops and
another process takes its port, that process serves cmux nothing: pages fall back to the overlay
or the bundle. A server you start some other
way, or on another machine, needs `CMUX_WEB_DEV_TOKEN` set to that token. A `server` with no
`token` is ignored. The scheme handler fetches each file from the server and answers it under the page's own
`cmux-page://` or `cmux-agent://` origin, so the host bridge and page trust stay the shipped ones.
While a dev server serves, the Content Security Policy is looser. Pages also allow inline scripts
(React Refresh) and that server's `ws://` and `http://` origin. The agent pane uses the dev
server's own policy, which allows inline scripts and loopback WebSockets and frames on any port.
An overlay keeps the shipped policy.

### A projection window

```sh
scripts/cmux-next/projection.sh open ~/src/cmux-wt --test 'bun test src/settings/theme.test.ts'
```

starts the worktree's webviews dev server on a port of its own (4290-4389) and runs **Debug > Open
Projection Window** (`debug.projection`): a new window of the running app whose pages and agent panes
load from that server. It is a real window of your app, so it has your settings, theme, backdrop,
keys and the live daemon's terminals; its first workspace is in the worktree and shows the New Tab
page, which is native: pass `--page settings` (or `history`, `keybindings`, ...) to open a web page
there too. Saving a web
file in the worktree hot-reloads that window only (Vite HMR; React Fast Refresh keeps component
state). Your other windows keep their pages, and `web-dev.json` is not touched. While a projection
is open, newly opened pages use WebKit in every window, as with `web-dev.json`. Settings, theme and
keybinding edits in `cmux-next.json` apply to every window live, the projection included.

**Debug > Run Projection Test** (`debug.projection.runTest`, or `projection.sh test [CMD]`) runs the
`--test` command in a new workspace of the projection window, in the worktree, and keeps its output.
`projection.sh stop <worktree>` stops the server; closing the window ends the projection.
`projection.sh serve <worktree>` starts only the server and prints its URL.

### Live copies, side by side

Try several versions of one web change at once (one per agent, say) and keep the best:

```sh
scripts/cmux-next/live-copies.sh start 3                     # 3 copies of origin/feat-cmux-next
scripts/cmux-next/live-copies.sh start 3 --from my-branch    # 3 copies of one branch
scripts/cmux-next/live-copies.sh start --from 36378 --from 36340 --from lane/x --open
```

Each copy is a worktree of its own on a branch of its own (`live-copy/<set>/<n>`), with its own
webviews dev server (`projection.sh serve`, ports 4290-4389) and its own state folder, so the agent
pane's git and file reads see that copy. `start` prints each worktree: point one agent at each.
Saving a web file in a copy hot-reloads only that copy. node_modules is a copy-on-write clone of
this checkout's, so a copy starts in seconds.

The compare page (`--open` puts it in a cmux browser tab; `live-copies.sh compare` rewrites it with
each copy's changed files) shows every copy side by side, live, on one path (`--page`, default
`/agent-pane/?mock`; edit the path box to switch them all). `--windows` also opens each copy as a
projection window of your running app, with your glass and settings. **Keep this one** opens the
copy's pull request, or the form that opens one; `live-copies.sh keep [SET] N [--push]
[--stop-others]` does the same from a terminal and pushes the copy's branch. A copy made from a
PR is on a branch of its own, so keeping it never pushes onto that PR. `stop` ends the servers,
`rm` the worktrees (it refuses unsaved or unpushed work without `--force`).

### A pull request

```sh
scripts/cmux-next/web-overlay.sh follow <PR>
```

fetches the PR's head with git (no GitHub API) into one checkout the script keeps under
`~/Library/Caches/cmux-next/web-slot/follow`, and runs the dev server there. Run it again after a
push: it checks out the new head in place and the open pages hot-reload, so you review exactly the
head under review. `status` names the PR and commit it follows; `server off` stops it.

The dev server runs the head's own code (its Vite config and dev-server plugins) on your Mac. A
head that no branch of the repo points at, such as an outside contributor's fork, is refused until
you have read its `webviews/` changes and add `--fork`.

### Try a pull request without knowing what it changed

```sh
scripts/cmux-next/try-pr.sh <PR>            # --here for your own app, --dry-run to only look
scripts/cmux-next/try-pr.sh <PR> --stop     # quit and remove its side instance
```

reads the PR's diff with git and takes the cheapest path, in a side instance by default: a copy
of your cmux NEXT named "cmux PR #N" with its own bundle id, data, settings and web overlay
(`scripts/cmux-next/side-instance.sh`), so your app's data, sessions and settings stay apart. The copy
starts signed out with fresh settings and never updates itself; cmux links still open your app.
Like every cmux build on the Mac, it shares two folders with your app: `agent-home` (the folder a
chat with no folder runs in, so its Home chats see your Home chats' files) and `Chat Uploads`.
`try-pr.sh <PR> --stop` quits it with its terminal daemon and deletes it and the data it kept.

- A web-only PR is patched in: the side instance opens and `web-overlay.sh follow` serves the PR's
  web UI to it, with no build. Later pushes and edits hot-reload.
- A PR that changes only CI, tests or docs is reported as nothing to try.
- A PR that changes the daemon, Swift, a resource or a manifest needs a new binary: the script says
  why (a stored property, a changed signature, a new type in an existing file, and so on), requests the fleet dev build
  tagged `pr-<N>`, waits for it and opens that build as the side instance. `--no-build` stops at
  the verdict.

`--here` patches your running app instead (web-only PRs) and, for a rebuild, only says where the
build is. The rules are in `scripts/cmux-next/live_apply.py`. Over the last 3,895 NEXT-era PRs,
about half of the ones that touch the app changed only web code or nothing in the app, so they
need no new binary.

A Swift change confined to function bodies can also skip the build when `--from` names a live code build
([live-code.md](live-code.md)) and `--live-code` its reload log:

```sh
scripts/cmux-next/try-pr.sh <PR> --from "<your live code build>.app" --live-code /tmp/cmux-reload-<tag>.log
```

The script puts the PR's diff onto the build's own commit (`CMUXCommit`) in a scratch worktree and sorts it
again there. When every change is an edit to an existing `CmuxNextApp` Swift file, `scripts/live-code/patch.py
--tree` compiles those files against the build into the side instance's `live-code/` folder, and the running
copy loads them. With `--here`, the files go to your own app's live folder (Labs > Live Code). A new or deleted
file, a change outside `CmuxNextApp`, a commit this checkout lacks, a failed compile or a patch the app refuses
all take the dev build instead, and the script says which one it was. The build's commit comes from its
`CMUXCommit`, which reload.sh, the fleet and the nightly stamp. A build marked `CMUXCommitDirty` (tracked files had
local changes) or one that records no commit takes the dev build too. Only Debug and bench builds load patches
today, so the installed nightly still takes the dev build. `scripts/measure/try-pr-live-code.sh` runs the whole
path on a fleet Mac: a live code bench build, a PR that turns Home red (it applies, captured before and after) and
one that calls a method only its newer base has (it takes the dev build).
`scripts/measure/try-pr-side-instance.sh` times a set of PRs from the command to the PR's page
loading in the side instance.

### An agent's loop: apply, probe, roll back

```sh
scripts/cmux-next/live-apply.py --probe 'CMD'   # --base SHA (the app's CMUXCommit), --repo DIR, --dry-run
```

applies this checkout's working tree (tracked edits and untracked files) to the running app with the
cheapest rung that covers it, runs `CMD` until it exits 0 or `--probe-seconds` (30) runs out, rolls
back to the previous overlay generation when it does not, and prints one JSON line an agent reads
before its next edit:

```json
{"rung": "R0", "applied": true, "probe": "pass", "seconds": 41.2, "rolled_back": false, "verdict": "web-live", "needs": null, ...}
```

Today the one rung is R0, web bundles (built with `web-overlay.sh build` and swapped in, same
process). A Swift, daemon or rebuild change applies nothing and says what it needs (exit 3); Swift
function bodies join once the app's live Swift loader lands (hq#7149 R2). The overlay must be on in
Debug Settings (Live web reload). `scripts/measure/agent-loop.sh` runs the whole loop on the newest
NIGHTLY: a scripted Settings change, applied, probed through the app's `errors.list` (the page logs a
nonce), then a failed probe that must roll back, with the app the same process throughout.

### No dev server: built bundles

`fleet` needs the team's `cmux-ci` client.

```sh
scripts/cmux-next/web-overlay.sh fleet --ref <sha>      # the fleet builds that commit, no build on your Mac
scripts/cmux-next/web-overlay.sh install-app <app>      # the web bundles of any built cmux app
```

Both install the built agent pane, pages and viewers as an overlay in
`~/Library/Application Support/cmux-next/web-overlay`, and the app reloads when the install
finishes. `manifest.json` there records the commit they came from.

### A shared slot

To share one dev server, declare `"slot": {"host": "<ssh host>", "port": N}` in `web-dev.json`.
The host must be a shared build host, never someone's personal machine. `server --slot` tunnels the same port, so HMR still connects, and falls back
to `--local` when the slot doesn't answer. It copies the token from the slot's own
`~/.config/cmux/web-dev.json` over ssh; a slot without one warns, and its server then needs
`CMUX_WEB_DEV_TOKEN`. If the slot's server restarts with a new token, run `server --slot` again;
until then pages fall back to the bundle.

## The daemon's Rust, live

The terminal daemon (`cmux-tui`) and the agent daemon (acpmux, `cmux-tui-acpmux`) are Rust. Edit them
in a checkout and the running daemon becomes your build a few seconds after each save, with every
terminal, its scrollback and its shell process, and every agent session kept:

```sh
cmux live start --rust --build-host HOST     # or no --build-host to build on this machine
cmux live status                             # the last swap: when, which save, each step's time
cmux live stop --rust                        # stop watching; the daemon keeps the last build
```

On each saved `.rs`, `Cargo.toml` or `Cargo.lock` under `cmux-tui/`, the loop
(`scripts/cmux-next/rust-live.py`):

1. builds only the daemons the changed crates reach (`cargo metadata`), incrementally. With
   `--build-host` the changed files go to a tree kept for this checkout on that host (rsync over one
   kept ssh connection), which keeps its own warm `target/` and uses sccache when the host has it;
2. brings the binaries back (rsync, compressed) into a new folder per build, so the running daemon's
   file is never written over;
3. swaps the daemon the way `scripts/cmux-next/daemon-swap-check.py` measures it: the old owner
   stops and leaves its terminal hosts running, the new one adopts them (`server restart` when the
   build has it, else `server stop` and `server ensure`; `daemon restart` for acpmux).

The build host builds for the daemon's platform: a Mac build box for the app's daemon on a Mac, any
Linux box for a daemon on Linux. Pass `--session NAME` for a daemon other than the default session
(`cmux-app-<tag>` for a tagged build). A build error is logged (`cmux live status` shows it) and the
running daemon stays as it was. The next app launch hands the session back to the daemon bundled in
the app.

Measured with `scripts/measure/rust-live-swap.sh OUT` (a scratch daemon with three shells, then
one-line edits to `identify` in cmux-tui-core, each timed from the save to the swapped daemon
answering with the edit; every shell checked to be the same process, with its screen, still echoing):

| Step (20 one-line edits, a 32-core fleet Linux box, building there) | p50 | p95 |
|---|---|---|
| Save to swapped (daemon answers with the edit) | 42.2 s | 44.1 s |
| Seeing the save | 0.29 s | 0.34 s |
| Incremental build: cmux-tui-core, cmux-remote, cmux-tui, link | 41.4 s | 43.4 s |
| Swap (`server stop` + `server ensure`), 3 terminals kept | 0.36 s | 0.64 s |

All 20 swaps kept all three shells: same process, screen kept, still echoing. Nearly all the time
is the compile: cmux-tui-core is about 450k lines and cmux-tui about 300k, and opt-level 0 for our
crates saves nothing (it's the front end, not codegen). Splitting those crates is what brings this
toward a second. From a build host on another machine add the copy: the debug `cmux-tui` is 614
MB, 263 MB once the build host strips its debug info (the loop does), and rsync sends only the
change against the last build. That took 19 s from the fleet box to a Mac over the tailnet.

The in-place patch (`hotpatch` feature, `scripts/cmux-next/daemon-hotpatch-check.py`) keeps even the
daemon's process and its client connections, but on the same box it is slower: 64.2 s for its edit
in cmux-tui-core (dx replays cmux-tui-core's rustc, then rebuilds the program crate), after a 353 s
first build. So the loop swaps instead.

### Editing while it runs: what survives

`bun run hot-reload:proof` (in `webviews/`) checks this on the real agent pane with no app: it
starts the dev server `server --local` runs and opens `/agent-pane/?mock`. For each source edit it
sends a prompt so a fresh turn streams, types a draft, saves the edit, and checks that it shows up
in the same page with the draft, the transcript and the streaming turn kept. `--audit` also saves every pane
component the page loaded, one at a time, and lists the ones that reload the page instead. It
undoes every edit before it exits. Run it on the fleet with
`cmux-ci test -- bash -c 'cd webviews && node scripts/hot-reload-proof.mjs --audit "$FAST_CHECKS_OUT"'`.

Measured on `feat-cmux-next` (2026-11-05, fleet Linux runner, Chromium):

| Edit, mid-turn | Result |
|---|---|
| A stylesheet (`bottomStack.css`) | Shown in 0.6 s, same page; the draft, transcript and turn are kept |
| A component (`ComposerFoot.tsx`) | The page reloads (2.2 s); the draft and transcript are lost and the turn stops streaming |
| Every loaded pane component (`--audit`) | 187 of 319 hot-swap in place; 132 reload the page |

A component reloads the page when React Fast Refresh can't swap its module: the file also exports
something that is not a component (a context, a constant, a helper), so Vite passes the update up
to the files that import it. `ComposerFoot.tsx` exports the `InQuietRow` context; its importer
`NewTabPage.tsx` (constants and helpers) can't take the update either, nor can `App.tsx`, which
imports that (`applyPaneTheme`, `saveSnapshot` and others), and the update reaches the page root,
which reloads. Vite logs
`Could not Fast Refresh ("NAME" export is incompatible)` for each. Moving those exports into
sibling `.ts` files makes the component edits swap in place.

Beyond the web UI, Swift views take live code today only in the view shell
(`Prototypes/ViewShell`, "Live code" in its README): function bodies and new files apply to the
running shell with no relaunch. The app itself still needs a build for Swift; `try-pr.sh` says
which PRs do.

## Every merge, no checkout

Settings > Updates > **Web UI Updates**:

- **Every Merge:** the web UI of each `feat-cmux-next` merge arrives minutes after it lands, signed.
- **With Nightly:** the web UI only changes when the nightly app updates.
- **Off:** the web UI the app shipped with.

A web update never runs over your own dev server or overlay. A page loads from, in order:

1. the dev server;
2. the live overlay;
3. the signed web update;
4. the bundled files.

Only NIGHTLY bundles take web updates; Debug builds keep the developer's own pages. The plan is in
[web-ota.md](../../plans/cmux-next/web-ota.md).

## Troubleshooting

| Symptom | Check |
|---|---|
| Nothing changes after `server --local` | `web-overlay.sh status` lists the dev server. `curl -sI http://127.0.0.1:4200/agent-pane/index.html` answers 200, and with `-H 'X-Cmux-Dev-Nonce: 1'` it adds an `X-Cmux-Dev-Proof` (none: the server is older than this change, or `web-dev.json` has no `token`). The app's commit includes #22664 (above). |
| A page loads, then stops updating | The dev server stopped. The page falls back to the overlay, then the bundle. Run `server --local` again. |
| `the dev server did not start` | Another process holds the port (the server won't move to another one). Use `--port N`; the app follows `web-dev.json`. |
| You see another tree's edits | A dev server that `web-overlay.sh` didn't start already answers on the port, and `server --local` reuses it. Stop it where it was started, or use `--port N` for a free port. |
| You want the shipped pages without deleting anything | Set `"enabled": false` in `web-dev.json`, or turn **Live Web Reload** off (`cmux settings set updates.liveWebReload false`). |
| Nothing changes, and `status` says the server runs | `cmux settings get updates.liveWebReload` says `true`. The app's commit includes this change (older NIGHTLYs also needed Debug Settings > Pages > Live web reload on). |
| Unstyled pages with no override running | Not the live loop. With no `web-dev.json`, the app serves its bundled files unchanged. Report it with the app's commit. |

The design and its edge cases are in [web-live-reload.md](../../plans/cmux-next/web-live-reload.md).

## Planned

None of this has shipped yet. Each step will be its own small PR:

1. **Under a second, every time.** Each edit would be measured end to end, from saving the file to
   the new frame in the app, and a check would fail when it goes over one second. A
   [recording](https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/22664/live-reload-settings.mp4)
   on a cmux NEXT nightly measured 0.7–0.85 s for a Settings edit.
2. **Show what's live.** A small chip in Debug and NIGHTLY builds would name what each page is
   loaded from: the dev server, an overlay at a commit, a web update, or the bundle.
3. **Reload what Swift can.** A change that only touches what a page reads from its host (strings,
   the settings schema, theme tokens) would reload the pages that use it. Native code still needs
   a build, which would come through the per-user update channel in the plan.
4. **No bridge skew.** An overlay or web update built for a newer page bridge than the app has would
   be refused, with the reason in `status`, so a page never calls a host op the app lacks.
