# Hot reload for the web UI

cmux NEXT's pages (Settings, History, Cloud, the viewers) and the agent pane are React webviews.
Running apps can pick up edits to them without a Swift build or a relaunch, two ways:

- **From your own checkout:** edits show up live in your app in about a second.
- **From `feat-cmux-next`:** a NIGHTLY follows each merge's web UI.

| You want | Do this |
|---|---|
| Your edits live in your app | `scripts/cmux-next/web-overlay.sh server --local` |
| Another worktree's edits live | `scripts/cmux-next/web-overlay.sh server --local --worktree <path>` |
| A pull request's web UI, live | `scripts/cmux-next/web-overlay.sh follow <PR>` (again after each push) |
| The web UI of every merge, no checkout | Settings > Updates > Web UI Updates > **Every Merge** |
| Stop your dev server | `scripts/cmux-next/web-overlay.sh server off` (an installed overlay, if any, still serves) |
| The shipped pages back | `scripts/cmux-next/web-overlay.sh off` (ignores the file; run `server off` first to stop the server) |
| What's running | `scripts/cmux-next/web-overlay.sh status` |

## Which apps read it

| App | Bundle id | Dev server and overlay (`web-dev.json`) | Every Merge web updates |
|---|---|---|---|
| Debug builds (tagged `cmux DEV <tag>`) | `com.cmuxterm.app.debug.*` | yes | no |
| cmux NIGHTLY, cmux NEXT nightly | `com.cmuxterm.app.nightly`, `….nightly.cmux-next` | yes, from #22664 on | yes, from #22777 on |
| cmux NEXT DEV (daily) | `com.cmuxterm.app.debug.next` | yes, from #24046 on | no |
| Release, RC | `com.cmuxterm.app`, `….rc` | never | never |

Check which commit your app was built from with
`/usr/libexec/PlistBuddy -c "Print CMUXCommit" "/Applications/cmux NIGHTLY.app/Contents/Info.plist"`.
The live loop needs that commit to include `abe5a602` (#22664).

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

While the file points at a server or an overlay, cmux's pages open in WebKit even when
`browser.defaultEngine` is Chromium (#23986). Chromium serves the bundled pages it was given when
it started, so it would never show your edit. A page that is already open in Chromium moves to
WebKit the next time it opens.

The server listens on loopback only, and the app accepts only a loopback URL in `web-dev.json`. The
scheme handler fetches each file from the server and answers it under the page's own
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
to `--local` when the slot doesn't answer.

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
| Nothing changes after `server --local` | `web-overlay.sh status` lists the dev server. `curl -sI http://127.0.0.1:4200/agent-pane/index.html` answers 200. The app's commit includes #22664 (above). |
| Settings doesn't change, the agent pane does | The app predates #23986, so Settings is still in Chromium. Set `browser.defaultEngine` to `webkit` in `~/.config/cmux/cmux-next.json`, or update the app. |
| A page loads, then stops updating | The dev server stopped. The page falls back to the overlay, then the bundle. Run `server --local` again. |
| `the dev server did not start` | Another process holds the port (the server won't move to another one). Use `--port N`; the app follows `web-dev.json`. |
| You see another tree's edits | A dev server that `web-overlay.sh` didn't start already answers on the port, and `server --local` reuses it. Stop it where it was started, or use `--port N` for a free port. |
| You want the shipped pages without deleting anything | Set `"enabled": false` in `web-dev.json`. In Debug and NIGHTLY builds, Debug Settings > Pages > **Live web reload (web-dev.json)** off also ignores the file; cmux NEXT DEV has no Debug Settings. |
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
