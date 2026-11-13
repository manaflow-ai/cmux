# Edit chat live in a tagged build

Use a tagged Debug app and local Vite servers to inspect chat edits as you save.
Vite hot module replacement (HMR) applies ordinary React and CSS edits without a native rebuild or app relaunch.
The app still supplies its native host bridge, theme, and daemon connection.

For the standard single-server workflow, use [cmux Live](hot-reload.md#start-in-30-seconds).
This guide describes the separate agent pane and pages servers used for chat parity work.

## Prepare the worktree

Use the same worktree for the source edits and both servers.
Keep the native app close to that worktree's revision.
New web code can require native bridge operations that an older app does not provide.

From the trusted worktree:

```sh
cd webviews
bun install --frozen-lockfile
node scripts/pages/gen-strings.mjs agentPane
```

Use the repository's worktree and build rules.
Agents must run native builds on the fleet, not on the developer's Mac.
A documentation change does not require a native build.

## Start the two servers

Use a separate terminal for each command.
Run both commands from the worktree's `webviews` directory.
Keep both terminals running during the editing session.

Agent pane:

```sh
CMUX_AGENT_PANE_DEV_PORT=4178 \
  CMUX_VITE_CACHE_DIR=/tmp/cmux-chat-live-agent-cache \
  bun run dev:agent-pane
```

Pages and the scenario workbench:

```sh
CMUX_PAGES_DEV_PORT=4292 \
  CMUX_VITE_CACHE_DIR=/tmp/cmux-chat-live-pages-cache \
  bun run dev:pages -- --host 127.0.0.1 --strictPort
```

The servers bind to loopback. Strict ports prevent an unnoticed switch to another port.
If a port is occupied, identify its owner before stopping anything.
Port 4178 is also a default gallery port in other workflows.
Use another free port if necessary, then update the corresponding app launch URL.
Do not use port 4190 for this setup; WebKit can block it.

| Server | Source root | Configuration |
|---|---|---|
| Agent pane, 4178 | `webviews/src/agent-session/acpmux` | `webviews/vite.config.acpmux-pane.mjs` |
| Pages, 4292 | `webviews` | `webviews/vite.config.pages-dev.ts` |

## Connect the tagged app

Configure the supported tagged-build launch with these environment variables:

```sh
CMUX_NEXT_AGENT_PANE_DEV_URL=http://127.0.0.1:4178/
CMUX_NEXT_PAGES_DEV_URL=http://127.0.0.1:4292/
```

These are **app launch variables**, not Vite port variables.
The tagged reload launcher preserves them when it creates the app's launch job.
Follow the [tagged build procedure](../../skills/cmux-dev-workflow/references/tagged-builds.md) for the initial native setup.
Follow the current fleet rules when an agent performs that setup.

The app reads the launch variables at startup.
Exporting them in an unrelated terminal does not update a running app.
Use the registered tagged launch job when reopening that app.
An ordinary launch can omit the environment required by this workflow.
Do not restart an app that has active user work to change these variables.

The Debug launch-variable route is separate from the shared `web-dev.json` route.
Do not rewrite the shared file just to repair one tagged app.
An active shared server or overlay can affect other builds.
Use [cmux Live status and troubleshooting](hot-reload.md#troubleshooting) when the loaded source is unclear.
Keep dev-server tokens out of source files and logs.

## Edit and inspect

1. Open a real chat in the tagged app.
2. Edit a component or stylesheet in the served worktree.
3. Save the file.
4. Inspect the change in the same chat.

Vite sends the update to the open web view.
CSS normally updates in place. React Fast Refresh normally replaces the changed component.
Some module export changes require a page reload.
Such a reload can reset a draft, scroll position, or disclosure state.
Do not assume that every edit preserves local UI state.

Chat components are under `webviews/src/agent-session/acpmux/`.
Scenario definitions are under `webviews/src/gallery/parity/`.
When translated text changes, update its catalog and regenerate the string table before inspecting it.
Run the focused checks required for the changed files.

Swift, AppKit, Rust, entitlements, and native bridge changes need their own build or deployment procedure.
Web HMR does not rebuild or restart those components.

## Use the scenario workbench

Open:

```text
http://127.0.0.1:4292/src/gallery/chat-parity.html?view=overview&scenario=full-conversation
```

Keep `/src/` in the path. `/gallery/chat-parity.html` is a different route and can return 404.
Select a scenario to inspect its synthetic conversation and interactive states.
Check the real app separately when behavior depends on the native host or daemon.

## Check the loaded source

Check that both servers answer:

```sh
curl -fsS http://127.0.0.1:4178/ > /dev/null
curl -fsS http://127.0.0.1:4292/@vite/client > /dev/null
```

The agent server uses the agent pane source root.
For example, inspect a served component at this path:

```sh
curl -fsS http://127.0.0.1:4178/conversation/MessageRunLine.tsx \
  > /tmp/cmux-chat-live-served-module.txt
```

Confirm that the served module contains the intended change.
Then inspect the tagged app.
An HTTP response proves server availability, not that the app applied the change.

| Symptom | Action |
|---|---|
| Edits do not appear | Check the worktree, server logs, app identity, and launch URLs. |
| The server has new source but the app has old UI | Check the app's launch environment and any active shared overlay. |
| A server cannot bind | Identify the listener on its port. Preserve another task's server. |
| HMR stops after closing a terminal | Restart that session's servers from the same worktree. |
| The app reports an unsupported bridge operation | Update the native host through the supported build procedure. |
| Chief does not reply while chat UI updates | Check the Chief executable and process separately. HMR supplies web source only. |

Stop each server with Ctrl-C in its own terminal when the editing session ends.
Do not stop servers or apps owned by another task.

## Implementation references

- [Agent pane setup](../../webviews/src/agent-session/acpmux/README.md).
- [Agent pane Vite configuration](../../webviews/vite.config.acpmux-pane.mjs).
- [Pages Vite configuration](../../webviews/vite.config.pages-dev.ts).
- [Tagged reload launcher](../../scripts/reload.sh).
- [General live editing workflow](hot-reload.md).
