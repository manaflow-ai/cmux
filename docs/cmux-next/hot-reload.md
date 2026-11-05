# Change cmux live

cmux's pages (Settings, History, Cloud, the viewers) and the agent chat are React. Edit them in a
cmux checkout and the app you're using right now changes as you save: no build, no relaunch, your
windows, chats and terminals stay where they are. It works in every cmux build, in WebKit and in
Chromium, and it's on by default.

## Start in 30 seconds

```sh
git clone https://github.com/manaflow-ai/cmux && cd cmux      # or any checkout you already have
scripts/cmux-next/web-overlay.sh server --local
```

Now edit anything under `webviews/src/` and save. Open pages and chats reload once onto your
code, then every save shows up in about a second, keeping each page's state (React Fast Refresh).

Done for now?

```sh
scripts/cmux-next/web-overlay.sh off      # the web UI the app shipped with; your files stay
```

| You want | Do this |
|---|---|
| Your edits live in your app | `scripts/cmux-next/web-overlay.sh server --local` |
| Another worktree's edits live | `scripts/cmux-next/web-overlay.sh server --local --worktree <path>` |
| A pull request's web UI, live | `scripts/cmux-next/web-overlay.sh follow <PR>` (again after each push) |
| Try any pull request the cheapest way | `scripts/cmux-next/try-pr.sh <PR>`: live when it can be, else it names the dev build |
| The web UI of every merge, no checkout | Settings > Updates > Web UI Updates > **Every Merge** |
| Stop your dev server | `scripts/cmux-next/web-overlay.sh server off` (an installed overlay, if any, still serves) |
| The shipped pages back | `scripts/cmux-next/web-overlay.sh off` (ignores the file; run `server off` first to stop the server) |
| What's running | `scripts/cmux-next/web-overlay.sh status` |
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
need no new binary. A Swift change confined to function bodies and new files could be injected live once the
app takes live code (the view shell does today); until then it takes the dev build.
`scripts/measure/try-pr-side-instance.sh` times a set of PRs from the command to the PR's page
loading in the side instance.

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
`CMUX_WEB_DEV_TOKEN`.

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
