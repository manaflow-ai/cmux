---
name: cmux-live
description: "Edit cmux's own web UI or daemon while it runs, and try a change or PR in the running app before asking for a dev build: the running cmux loads a checkout's webviews dev server (each saved edit shows at once, no build or relaunch) or a saved Rust edit to cmux-tui or acpmux (`cmux live start --rust`). Use when changing or trying anything under webviews/ (chat pane, Settings, Home, Markdown viewer), or for hot reload, live reload, 'cmux live', web-dev.json, try-pr.sh or hot-apply.py."
---

# cmux live

## Try it live before you ask for a dev build

Most cmux changes can be tried in the app that already runs (a nightly, a release or a DEV
build) with no app build and no relaunch. Before you request a dev build, or tell the person they
need one, take the first row that covers the change:

| The change | Try it with |
|---|---|
| Your edits under `webviews/` | `cmux live start --worktree <checkout>` (below) |
| Your edits to the daemon's Rust (`cmux-tui/`, acpmux) | `cmux live start --rust --build-host HOST` |
| Someone's pull request | `scripts/cmux-next/try-pr.sh N`: its web UI is served and a daemon PR's daemon is swapped in, in a side copy of the app (`--here` for the person's own app); it requests a dev build only when the PR needs one, and says why |
| A merged commit, before the nightly | `scripts/cmux-next/hot-apply.py apply SHA` (its web and daemon parts) |
| Swift edits inside function bodies | a live code build (`cmux live start --swift`, docs/cmux-next/live-code.md) |

Only a change none of these takes (a new stored property or type in existing Swift, a resource, a
manifest, Rust the app links through FFI) needs the dev build. `scripts/cmux-next/live_apply.py
BASE HEAD` sorts a change the same way try-pr does. Of the last 1,000 NEXT pull requests that touch
the app, about 42% go into a nightly this way with no build.

`cmux live start` runs a cmux checkout's webviews dev server (Vite) and points the running
cmux at it. From then on, a saved edit under `webviews/` shows in every open page and agent
chat, in WebKit and Chromium tabs alike, with no app build and no relaunch. Chats keep their
state; React components hot reload in place.

```bash
cmux live start                      # the checkout around the current folder
cmux live start --worktree ~/src/wt  # another checkout (a worktree for one change)
cmux live status                     # what cmux loads its web UI from
cmux live stop                       # back to the web UI cmux shipped with
```

A person does the same from the app: Cmd-Shift-P > **Edit cmux Live…** (it asks for the
checkout), **Stop Editing cmux Live**, or the same buttons at the end of Settings > General.

## How to work with it

1. Make or pick a worktree for the change and run `cmux live start --worktree <it>`. One dev
   server runs at a time; starting another checkout replaces the first.
2. Edit files under `webviews/`. Do not build the app or relaunch cmux to see the change; tell the
   person to look at the page or chat that changed.
3. Serve a tree close to the running app's commit (`cmux version` shows it): a much newer tree may
   call page bridge ops the app does not have yet.
4. When you are done, `cmux live stop`, unless the person wants to keep looking.

## The daemon's Rust

`cmux live start --rust` does the same for the terminal and agent daemons: each saved `.rs`,
`Cargo.toml` or `Cargo.lock` under `cmux-tui/` builds the daemons it reaches and swaps the running
daemon for the build, keeping every terminal (same shell process, same screen) and agent session.

```bash
cmux live start --rust --build-host HOST   # build over ssh on HOST; never build on the person's Mac
cmux live status                           # the last swap: which save, each step's seconds
cmux live stop --rust                      # stop watching; the daemon keeps the last build
```

The build host must build for the daemon's platform (a Mac build box for the app's daemon on a
Mac). A one-line edit in cmux-tui-core takes tens of seconds, nearly all of it compiling
(cmux-tui-core and cmux-tui are large crates); the swap itself is under a second. A build error
leaves the running daemon as it was; `cmux live status` shows the error.

## Chromium's renderer code

`cmux live start --chromium --build-host HOST --src SRC` does the same for renderer-side code in the
CEF fork: each file saved under `.cmux-dev/chromium/<chromium path>` builds `libcef` on HOST's warm
tree, swaps Chromium Embedded Framework inside the app, ends the app's renderers and reloads its
Chromium tabs. The app and every session stay up. Browser-process code still needs a relaunch, and
each swap waits about a minute for the framework to relink. `cmux live stop --chromium` puts the
tree back.

Swift outside function bodies still needs a build; edits inside them take a live code build (above).

## When it does not change

- `cmux live status` shows `web-dev.json` and the Live Web Reload setting. The switch is
  `updates.liveWebReload` (on by default); `cmux settings set updates.liveWebReload true` turns it
  back on.
- The dev server's log is in the status output's state folder (`dev-server.log`).
- cmux loads only a dev server that proves it holds the token `start` wrote; one started some
  other way is ignored. Start it with `cmux live start`, not `bun run dev` by hand.

The full guide, including remote slots and following a pull request's head, is
`docs/cmux-next/hot-reload.md`.
