# Change cmux live

cmux's pages (Settings, History, Cloud, the viewers) and the agent chat are React. Edit them in a
cmux checkout and the app you're using right now changes as you save: no build, no relaunch, your
windows, chats and terminals stay where they are. It works in every cmux build, in WebKit and in
Chromium, and it's on by default. The feature is called **cmux Live**.

### Is cmux Live the same as Live Web Reload?

Yes. It is one feature, and Live Web Reload was its old name. The setting Settings > General >
**cmux Live** (`updates.liveWebReload`) is its on switch: on, the app may load your checkout's web
UI; off, it shows the web UI it shipped with. `cmux live start` (or **Edit cmux Live…**) is the
web path: it runs your checkout's dev server for the React pages and chat under `webviews/`.
The other paths are flags: `cmux live start --swift` restarts a tagged DEV build into a live code
build for the app's Swift ([live-code.md](live-code.md)), and `cmux live start --rust` swaps the
daemon's Rust ([below](#the-daemons-rust-live)). When pages go blank or stop changing,
`cmux live status` says first what the app loads its web UI from and why.

## Start in 30 seconds

```sh
git clone https://github.com/manaflow-ai/cmux && cd cmux      # or any checkout you already have
cmux live start
```

Or, without a terminal: press Cmd-Shift-P, run **Edit cmux Live…** and pick the checkout. The same
button is at the end of Settings > General.

Now edit anything under `webviews/src/` and save. Open pages and chats reload once onto your
code, then every save shows up in about a second, keeping each page's state (React Fast Refresh).
Each save is also linted for the performance mistakes past fixes removed, and a finding shows in the
page's console ([modding-kit.md](modding-kit.md)).

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
| What the app loads its web UI from, and why | `cmux live status` |
| Your Swift live too, in a tagged build | `cmux live start --swift` restarts it into the live code build of its commit, sessions kept, and patches your edits in and every save; `cmux live stop --swift` restarts into the optimized build of your edits ([live-code.md](live-code.md#live-mode-restart-into-the-live-code-build-and-back)) |
| Turn the feature off | Settings > General > **cmux Live**, or `cmux settings set updates.liveWebReload false` |

## On and off

**cmux Live** (`updates.liveWebReload` in `~/.config/cmux/cmux-next.json`) is on by default.
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
- A PR that changes the daemon or CLI (Rust in cmux-tui or acpmux) swaps the PR's daemon into the
  side instance, with no app build: the copy keeps your app's Swift and web, and its daemon hands
  off to the PR's build as in [`cmux live start --rust`](#the-daemons-rust-live), terminals kept
  (`scripts/cmux-next/hot-apply.py apply --branch`). The binary is the one CI published for the PR
  head's cmux-tui tree (a same-repo PR's push publishes it; 35 of 40 sampled daemon PRs had it),
  else the `bin/cmux` of the PR's fleet dev build. A PR that also changes web UI gets that patched
  in too. It takes the dev build instead when the PR changes Rust the app links through FFI, or
  when your app was built after the PR branched and has Rust the branch lacks.
- A PR that changes Swift, a resource or a manifest needs a new binary: the script says
  why (a stored property, a changed signature, a new type in an existing file, and so on), requests the fleet dev build
  tagged `pr-<N>`, waits for it and opens that build as the side instance. `--no-build` stops at
  the verdict.

`--here` patches your running app instead (web and daemon PRs; `hot-apply.py rollback` puts your
daemon back) and, for a rebuild, only says where the build is. The rules are in
`scripts/cmux-next/live_apply.py`. Of the last 1,000 NEXT PRs (#36100 to #37575), 675 touch the
app; try-pr puts 42% of those into a nightly with no build (105 web, 181 daemon), up from 16% when
only web went in live (`scripts/measure/try-pr-live-share.py`). 26 more change Rust the app links,
79 are Swift a live code build takes, and 284 need the dev build.

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
path on a fleet Mac: a live code bench build, a PR that turns Home red and insets Home's transcript so the red
shows around it (it applies, captured before and after), and one that calls a method only its newer base has (it
takes the dev build). At 0f92b5e9 the first PR applied 10.87 s after try-pr started (compile 4.1 s, link 0.24 s,
70 functions, a 135 ms load into the running copy), and its red went from 6 to 180,171 pixels with no relaunch.
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
finishes. `manifest.json` there records the commit they came from and the page bridge they need
(`abi`, from `webviews/src/web-abi.json`). The app serves the overlay only when that `abi` is its
own, the rule it already applies to web updates: an overlay for another bridge would call host ops
the app lacks, so the app keeps its own pages and `web-overlay.sh status` prints `refused by <app>`.

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
   stops and leaves its terminal hosts running, the new one adopts them. How depends on who runs the
   daemon:
   - **A cmux app's daemon** (it runs from the app's `Contents/Resources/bin/cmux`) swaps the way the
     app hands off its own. The build is renamed over that file (the `cmux-tui` link next to it
     stays, so both names are one build), and the owner gets SIGTERM. The app's reconnect then runs
     its own `server ensure` from the file, with its own install key, so the app keeps its launch
     identity and pid. A new owner that doesn't answer in 35 s puts the file back.
     `cmux live stop --rust` puts the app's own build back and hands the daemon back to it.
   - **Any other daemon:** `server restart` when the build has it, else `server stop` and
     `server ensure`. acpmux uses `daemon restart`.

The build host builds for the daemon's platform: a Mac build box for the app's daemon on a Mac, any
Linux box for a daemon on Linux. Pass `--session NAME` for a daemon other than the default session
(`cmux-app-<tag>` for a tagged build), or `--socket PATH` when the app's daemon socket isn't the
session's default (an app sets its daemon's `TMPDIR`). A build error is logged (`cmux live status`
shows it), and the running daemon stays as it was.

On a side copy of a DEV app (cmux#36389, base 1773603b, PR eddb05df, cmux-tui built on the fleet), the
app handoff took 1.38 s to the PR's daemon, 1.34 s back and 1.16 s forward again. The app's pid and
three shells stayed the same and kept echoing. The PR's new `conductor_import.record` answered, and
its replay held across the rollback. These are swap times only, on a loaded Mac, after builds that
already existed. They are not save-to-swap times.

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
edits a copy of your checkout in a temporary directory, not the checkout itself, so a file you save
while it runs is never touched; the copy is deleted when it exits. Run it on the fleet with
`cmux-ci test -- bash -c 'cd webviews && node scripts/hot-reload-proof.mjs --audit "$FAST_CHECKS_OUT"'`.

Measured on `feat-cmux-next` (2026-11-05, fleet Linux runner, Chromium):

| Edit, mid-turn | Result |
|---|---|
| A stylesheet (`bottomStack.css`) | Shown in 0.7 s, same page; the draft, transcript and turn are kept |
| A component (`ComposerFoot.tsx`) | The page reloads (2.2 s); the draft and transcript are lost and the turn stops streaming |
| Every loaded pane component (`--audit`) | 246 of 369 hot-swap in place; 123 reload the page |

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

## Chromium's renderer code, live

cmux's own pages and Chromium tabs run on the CEF fork (manaflow-ai/cef). An edit to Blink or other
renderer code there can show in the running app without a relaunch: the app, its windows and every
session stay up, and only the renderer processes start again on the new build.

```sh
cmux live start --chromium --build-host HOST --src ~/cef/chromium/src   # a warm CEF tree on HOST
cmux live status                                                         # the last swap and its times
cmux live stop --chromium                                                # put the tree back, stop watching
```

Put each file you edit under `.cmux-dev/chromium/<path in chromium/src>` in your checkout (or pass
`--edits DIR`). On each save the loop (`scripts/cmux-next/chromium-live.py`):

1. sends the file to the warm tree on the build host; the tree's own copy is kept and `stop` puts it
   back;
2. builds `libcef` incrementally (`--out`, `--target`), which relinks Chromium Embedded Framework;
3. brings the framework back with rsync, so only the change crosses the network;
4. signs the copy ad hoc and renames it over the framework inside the app. The app's browser process
   keeps the file it mapped at launch; a helper started after the rename maps the new one;
5. ends the app's renderer processes (and the GPU process with `--gpu`) and reloads every Chromium
   tab with `cmux browser TAB reload`, which starts a renderer on the new code.

Use it on a tagged DEV build, against a tree at the CEF commit the app was built with, so the new
framework matches the app's CEF wrapper. Give the loop a tree of its own (an APFS clone of a warm
tree with `cp -c -Rp`, which keeps the timestamps the build needs), never a CI worker's cache: the
loop edits the tree while it runs. Browser-process code, and any edit that changes an interface both
processes use, still needs a relaunch, because the browser process keeps the old framework.

What sets the time is the relink of the one large framework, not the compile. On a fleet Mac (an
M4 Pro) an incremental CEF build relinked Chromium Embedded Framework in 60 s, with its debug symbols,
after a few seconds of compiling. Splitting Blink out of the framework in a development-only
configuration is what would bring that down; see the notes for the CEF fork's owners in the PR that
added this loop.

### A merged CLI change, before the nightly

A cmux terminal puts its app's `Contents/Resources/bin` first on PATH, so the `cmux` you type there
is the app's own file, which is also the file the app runs its daemon from. That file never changes
before the app updates. To run a merged commit's CLI sooner:

```sh
scripts/cmux-next/cli-swap.py apply --tree-key KEY --name 37024   # in a cmux terminal
cmux-37024 machine new                                            # the merged CLI, beside the app's
scripts/cmux-next/cli-swap.py undo
```

KEY is `scripts/cmux-next/pin-cmux-tui.sh key` at the merged commit; the macOS CLI is published under
it after the merge. `apply` checks its sha256 and puts it on PATH as `cmux-NAME` (in `~/.local/bin`).
The app, its daemon and its terminals are untouched. A `cmux` that is a link outside any app is
repointed instead, and `undo` points it back.

### A merged commit in the running app, before the nightly

```sh
scripts/cmux-next/hot-apply.py plan SHA                 # what of SHA can go in, and what needs a nightly
scripts/cmux-next/hot-apply.py apply SHA                # put it in the running app
scripts/cmux-next/hot-apply.py rollback                 # the build and overlay that ran before
```

`--app` names the app (default `/Applications/cmux NIGHTLY.app`). `apply` builds nothing: it takes
what feat-cmux-next published for SHA and diffs it against the app's `CMUXCommit`:

- **Rust:** the `cmux` binary of SHA's cmux-tui tree key, checked against the sha256 in its
  `completion.json`, replaces the app's `bin/cmux`. The app's daemon then hands off to it as in
  `cmux live start --rust`: same app pid, terminals kept. `bin/cmux` is also `cmux-tui` and `acpmux`,
  so `cmux link`, the CLI in the app's terminals and acpmux daemons started after the swap run SHA's
  build. A running acpmux daemon keeps its build until it restarts (`--acpmux-home H` restarts one).
- **Web:** SHA's published web bundles go into the app's web overlay, as long as SHA's web ABI is
  the app's.
- **Neither:** Swift, resources, Rust the app links through FFI, and helpers such as
  cmux-mobile-host still need the nightly. `plan` lists them under `left`.

Each part is checked after it goes in: `bin/cmux` hashes to the published sha256 and a new daemon
answers from it, and the overlay names SHA. A part that fails its check is put back. SHA must come
after the app's commit, and the swap carries every change between the two. Swapping `bin/cmux`
breaks the bundle's seal until `rollback` or the next update. The running app does not notice.
`scripts/measure/hot-apply-nightly.sh` runs apply and rollback on a copy of the newest nightly on a
fleet Mac.

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

## Runtime perf budgets

Every page the dev server serves (`cmux live`, `bun run dev`, the agent pane's own dev server)
runs a few runtime budgets while you use it. When your change breaks one, the page's console (Web
Inspector, or Chrome DevTools in Chromium) shows one warning, once per place:

```
[cmux perf budget] dom-breadth: 1000 children over the budget of 300 children at ul.projects. Fix: render the visible window: VirtualList (src/ui/VirtualList.tsx) or Combobox virtualRows (src/ui/Combobox.tsx); ...
```

| Class | Fires when | Fix |
|---|---|---|
| `layout-shift` | Something moved 8 px or more after it painted with no input, or many small moves add up past a 0.01 shift score in a second (Chromium) | Reserve the final size before the first paint, or move it with a transform |
| `dom-breadth` | One element has more than 300 element children: a list drawn whole | `ui/VirtualList.tsx`, or `virtualRows` on `ui/Combobox.tsx` |
| `live-intervals` | More than 20 `setInterval` handles are live; names the call site holding most | The page clock: `subscribePageSecond`, `usePageNow`, `visibleInterval` (`ui/pageClock.ts`) |
| `long-frame` | A frame takes over 50 ms; names the longest script (Chromium) | Do less per frame: render the visible window, defer off-screen work |
| `react-commit` | A React root commits more than 120 times in a second, or renders for more than 16 ms in one update | Re-render only what changed: a streamed item reads its own value, batch to one commit a frame |
| `still-surface` | A surface marked `data-perf-still` (the agent pane's composer and the hat over it) has its nodes or attributes rewritten in more than 6 of the last 10 seconds with no key or pointer input: a clock tick or another chat's event draws it again | Memoize it on what it shows (`composer/composerView.ts`); a ticking value is a leaf of its own (`subagents/Elapsed.tsx`) |

The page's load and the second after each hot update are not budgeted for shifts, frames and
commits. Mark an element that must stay wide with `data-perf-budget-allow="<why>"`. Turn the
budgets off for a page with `?perf-budgets=off` or `localStorage["cmux.perfBudgets"] = "off"`, or
for the whole server with `CMUX_PERF_BUDGETS=off`. Tests set `window.__cmuxPerfBudgets = { mode:
"collect" }` (or `"throw"`) before the page loads and read `window.__cmuxPerfBudgetsHandle.violations`.
Built bundles carry none of this. The code is `webviews/src/devkit/perfBudgets.ts`.

## Troubleshooting

| Symptom | Check |
|---|---|
| Nothing changes after `server --local` | `web-overlay.sh status` lists the dev server. `curl -sI http://127.0.0.1:4200/agent-pane/index.html` answers 200, and with `-H 'X-Cmux-Dev-Nonce: 1'` it adds an `X-Cmux-Dev-Proof` (none: the server is older than this change, or `web-dev.json` has no `token`). The app's commit includes #22664 (above). |
| A page loads, then stops updating | The dev server stopped. The page falls back to the overlay, then the bundle. Run `server --local` again. |
| `the dev server did not start` | Another process holds the port (the server won't move to another one). Use `--port N`; the app follows `web-dev.json`. |
| You see another tree's edits | A dev server that `web-overlay.sh` didn't start already answers on the port, and `server --local` reuses it. Stop it where it was started, or use `--port N` for a free port. |
| You want the shipped pages without deleting anything | Set `"enabled": false` in `web-dev.json`, or turn **cmux Live** off (`cmux settings set updates.liveWebReload false`). |
| Nothing changes, and `status` says the server runs | The first lines of `cmux live status` say what the app loads and why. `cmux settings get updates.liveWebReload` says `true`. The app's commit includes this change (older NIGHTLYs also needed Debug Settings > Pages > Live web reload on). |
| `status` says `refused by <app>` | The overlay was built for another page bridge (`abi` in its `manifest.json`, from `webviews/src/web-abi.json`) than the app has, so the app serves its own pages instead of calling host ops it lacks. Build the overlay from a tree at the app's ABI (near its `CMUXCommit`), or run a build of that tree. A web update is refused the same way. |
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
