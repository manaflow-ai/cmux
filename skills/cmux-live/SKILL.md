---
name: cmux-live
description: "Edit cmux's own web UI while it runs: point the running cmux at a checkout's webviews dev server so every saved edit shows at once in every open page and chat, with no build and no relaunch. Use when changing or trying anything under webviews/ (agent chat pane, pages such as Settings, Home and the new tab page, the Markdown viewer), when the user wants to see a UI change live in their own app, or asks for hot reload, live reload, 'edit cmux live', 'cmux live', the dev server or web-dev.json."
---

# cmux live

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

Swift and Rust changes still need a build; only the web UI loads live.

## When it does not change

- `cmux live status` shows `web-dev.json` and the Live Web Reload setting. The switch is
  `updates.liveWebReload` (on by default); `cmux settings set updates.liveWebReload true` turns it
  back on.
- The dev server's log is in the status output's state folder (`dev-server.log`).
- cmux loads only a dev server that proves it holds the token `start` wrote; one started some
  other way is ignored. Start it with `cmux live start`, not `bun run dev` by hand.

The full guide, including remote slots and following a pull request's head, is
`docs/cmux-next/hot-reload.md`.
