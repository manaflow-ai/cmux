---
name: cmux
description: End-user control of cmux topology and routing (windows, workspaces, panes, tabs, terminals, focus, moves, identify, flash). Use when automation needs deterministic placement and navigation in a multi-pane cmux layout.
---

# cmux Core Control

Non-browser cmux topology and routing. The `cmux` CLI is noun-first: `cmux <scope> [<selector>] <verb>`.

- **Window**: top-level macOS cmux window, owned by the app.
- **Workspace** (`ws_…`): a sidebar entry.
- **Screen** (`screen_…`): a layout inside a workspace.
- **Pane** (`pane_…`): a split region in a screen.
- **Tab** (`tab_…`): a tab in a pane, showing a terminal or browser.
- **Terminal** (`term_…`): terminal content, addressable with or without a tab.
- **Room**: a personal view that shows the workspaces pinned to it and those of the sessions it follows. Rooms, workspace groups and tab or screen groups take their id or exact name (`cmux room --help`).
- **Closed history**: recently closed tabs, screens and workspaces (`cmux closed list`, `cmux closed <id> reopen`).

## Fast start

```bash
cmux app identify                                  # which app and socket
cmux terminal "$CMUX_TUI_TERMINAL_ID" show --json  # the caller terminal
cmux window list
cmux workspace list
cmux pane list
cmux tab list
cmux workspace create --name api
cmux pane pane_… split --right -- npm run dev     # new pane running the argv; focus stays
cmux pane pane_… run -- npm run dev                # new tab in an existing pane
cmux tab tab_… move --workspace ws_… --screen screen_… --pane pane_… --index 0
cmux pane flash-focused                            # attention cue (app action)
```

## Show UI in a chat reply

Embed screenshots instead of describing a UI change: a cmux chat draws `![alt](/abs/path.png)`, a bare image path, a `file://` URL or an https image address (PR media) as a thumbnail that opens full size on click. Put a before/after pair in one paragraph (`![Before](/tmp/a.png) ![After](/tmp/b.png)`, or `Before: /tmp/a.png` and `After: /tmp/b.png` on two lines) and it draws side by side. `#N`, `owner/repo#N`, `hq#N`, commit SHAs and `path/to/file.ts:42` become links.

## Which `cmux` to run

Inside a cmux terminal, `$CMUX_BUNDLED_CLI_PATH` is the CLI that ships with the running app. A login shell (`zsh -lc`, which Codex and other agents use) can put an older `cmux` first on `PATH`, for example a `uv tool` or `pipx` install of the PyPI `cmux` package. That CLI can lack verbs such as `browser page`. When a verb or flag that this skill documents is missing, run `"$CMUX_BUNDLED_CLI_PATH"` instead, or define `cmux() { "${CMUX_BUNDLED_CLI_PATH:-cmux}" "$@"; }` once per shell. Do not run `cmux daemon stop` to cure a version mismatch: it stops the user's session.

## Selectors

Every instance selector is a public id (`ws_…`, `pane_…`, `tab_…`, `term_…`), `caller`, `current`, or an exact name. `name:<value>` forces a name; it is required for names equal to `current` or `caller`, shaped like an id, or containing `_`. An ambiguous name fails with every candidate id. `caller` is the workspace, screen, pane, tab or terminal the command runs in (its terminal or agent chat, as `cmux identify` reports). Inside cmux, `current` means the caller's object too; it is the focused object only without a caller (a shell outside cmux) or under `--socket`/`--session`. Prefer `caller` in scripts: it fails instead of guessing. Ids are stable across app and daemon restarts. The old `window:N`, `workspace:N`, `pane:N` and `surface:N` refs are gone.

## Running a command in a new terminal

`cmux pane <sel> run -- <argv…>` opens a tab in that pane running the exact argv; `run shell '<script>'` passes a script to the shell. `--on-exit close|keep|shell` controls the tab after the process exits (`shell` drops it into a new shell), and `--cwd`/`--name` set its directory and title. `cmux workspace <sel> run` does the same in a workspace. The app action `cmux workspace new --command "…"` types the command into a new workspace's shell.

## App actions

Every action in the app's registry is also a verb: `cmux action list --noun workspace` lists them and `cmux action describe "<noun> <verb>"` shows arguments. Run one with `cmux <noun> <verb> [--target ID] [--<arg> VALUE]`, for example `cmux workspace set-color --target ws_… --color blue`. The daemon grammar is tried first; words it rejects run as an app action.

## Showing your work to the person

None of these moves the person's focus; `cmux docs search "show the user"` prints the same guide.

```bash
cmux agent open SESSION_ID [--group G]                # that agent session's chat, in a new workspace (in sidebar group G)
cmux workspace ws_… status set build "tests passing"   # a status line on the workspace's sidebar row (--state, --ttl…)
cmux workspace ws_… progress set 0.4 --label "3 of 8"
cmux notify --title "Review ready" --body "PR #123"    # --desktop false: sidebar marker only
cmux attention request --tab tab_… --reason "Confirm GitHub access"   # the person must act in this tab
cmux attention clear --tab tab_…
```

When the person must do something in a specific tab (confirm, log in, approve, pick), mark that tab with `cmux attention request` (MCP `tab_update {tab, attention: "reason"}`). The tab and its workspace row show as needing them, without moving their focus. The mark clears when you clear it, when a browser tab goes to another page, or when the tab closes. In what you tell the person, name the workspace and the tab by their titles ("the GitHub tab in the coord-deputy workspace"), never by a `ws_…`, `tab_…` or `pane_…` id: they cannot see or search ids. When they ask to go there, `cmux tab tab_… focus` (MCP `tab_focus`) takes them to it.

To start another agent on a task and show it, use one command, `acpmux new -n NAME --worktree REPO@BASE --prompt-file BRIEF.md --report-to ME --group G -d` (the `acpmux` skill): it makes the worktree, starts the session, sends the brief and opens its chat in group G; running it again changes nothing.

To open a link, the MCP tool `workspace_open_url` loads it on the workspace's right side, but it navigates a browser tab already there; `cmux browser profile open URL --profile default --background true` (MCP `browser_profile_open` with `activate: false`) adds a tab and keeps the pane's selected tab. `tab focus`, `workspace focus`, `agents tab select` and `focus: true` do move the person's focus: use them only when asked. `current` is the workspace the person looks at, not yours: from a cmux terminal `status set` without a selector targets that terminal's workspace, but an agent chat has no terminal, so name the workspace (`$CMUX_WORKSPACE_ID` when set).

## Asking the person

The person allows tools through the chat's mode and the harness's own permission prompts, never through your questions. A chat in Full access (Claude Code `bypassPermissions`, Codex full access) has already allowed every tool call its harness would ask about. Never ask them to allow, confirm or approve a step, with AskUserQuestion or in text ("allow this?", "should I go ahead?"): decide, say why in one line, and go on. Deciding never widens the task: a step a cmux skill keeps for the person's own request (importing a browser's cookies, deleting their data) waits for that request, and a cmux consent card (computer use setup) is theirs to answer; leave such a step out and say so. Ask only about product taste you cannot settle from the request or the code (how something should look, read or behave), and ask it as that choice, never as a permission. The cmux MCP server's instructions say the same (`acpmux::agent_tools::ASKING_RULE`).

## Screenshots of the app

Agents without Screen Recording permission can still see cmux: these verbs write a PNG of cmux's own windows. They never focus, raise or activate anything, and they work while the window is in the background or covered.

```bash
cmux window screenshot --out window.png                 # the focused window
cmux window screenshot --target win_… --out -           # PNG inline as base64
cmux pane screenshot --target pane_… --out pane.png
cmux tab screenshot --target tab_… --out tab.png
```

The reply's `result` holds `path` (or `png_base64` for `--out -`; a PNG over 4 MiB still goes to a file), `width` and `height` in pixels, `scale` (pixels per point), `method` (`window`) and `masked`, how many areas the image covers. Without `--out` the PNG goes to the temporary directory. A pane or terminal tab that no window shows, or a minimized window, fails with `screenshot.unavailable` and the reason; read a terminal's text with `cmux terminal <id> screen read` instead.

Your image comes back masked: every area that can show a browser page, a chat or an unchecked app page is filled opaque mid gray, and menus and floating panels are left out. That is every browser pane whole, its toolbar and tab strip included, every web view cmux does not own (a sidebar app, a link preview), every agent chat and Home conversation, and every app page except Keybindings, Changelog, Apps, Diff, Markdown, Editor, Files, the icon picker and Debug Settings. Only the browser REPL can hide the secrets a page shows, and only `cmux agents chat read` can hide them in a chat. A pane or tab showing a browser is captured with its page masked, not refused; a browser tab that no window shows is refused, because off screen it is all page. A window that keeps animating or resizing, or a mask that cannot be painted, fails with the reason rather than returning unmasked pixels. Screenshot a page with `browser_repl_eval` and `page.screenshot()` ([cmux-browser](../cmux-browser/SKILL.md)). A person's palette or menu run captures everything and also copies the image.

## Settings

cmux-next settings live in `~/.config/cmux/cmux-next.json`. With the app running, `cmux settings get [PATH]`, `cmux settings set PATH VALUE` and `cmux settings reset PATH` read and write it; `cmux settings validate` checks it without the app. Keys come from `schemas/settings/settings-schema.json`, not classic `cmux.json`; see [cmux-settings](../cmux-settings/SKILL.md) before editing.

Terminal rendering (cursor style, scrollback) belongs in Ghostty config; font family, font size and theme default to Ghostty config and can be overridden in cmux settings.

## Deep-dive references

| Reference | When to Use |
|-----------|-------------|
| [references/handles-and-identify.md](references/handles-and-identify.md) | Selectors, ids, and finding the caller |
| [references/windows-workspaces.md](references/windows-workspaces.md) | Window and workspace lifecycle, order, and context-menu actions |
| [references/panes-surfaces.md](references/panes-surfaces.md) | Splits, tabs, moves, focus |
| [references/trigger-flash-and-health.md](references/trigger-flash-and-health.md) | Flash cue; surface health was removed |
| [../cmux-workspace/SKILL.md](../cmux-workspace/SKILL.md) | Current caller workspace rules and non-disruptive automation |
| [../cmux-settings/SKILL.md](../cmux-settings/SKILL.md) | Safe settings edits |
| [../cmux-browser/SKILL.md](../cmux-browser/SKILL.md) | Browser tabs |
