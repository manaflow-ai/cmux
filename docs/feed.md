# Feed

Feed is cmux's inline surface for AI agent decisions. It stays in the right sidebar on `Ctrl-4`. The keyboard-first OpenTUI Feed can also run in the separate right-sidebar [Dock](dock.md) with `cmux feed tui`. It shows three things that need a human response:

- **Permission requests:** Agent wants to run a tool, edit a file, or execute a shell command. Pick Once / Always / All tools / Bypass / Deny.
- **ExitPlanMode:** Agent finished planning and is ready to start editing. Pick Ultraplan / Manual / Auto.
- **AskUserQuestion:** Agent is asking a multiple-choice question. Pick one (or several) and hit Submit.

Anything else the agent does, including tool uses, assistant messages, session starts/stops, and `TodoWrite` updates, is stored and shown in the TUI's latest-first timeline as informational activity.

`cmux feed tui` uses OpenTUI through Bun in the terminal alternate screen. The first run creates `~/.cmuxterm/feed-tui-opentui`, writes the bundled Feed app there, and installs `@opentui/core`. The prepared app is launched by absolute path, so the TUI keeps the workspace cwd where you ran the command. Use `cmux feed tui --opentui` to dogfood OpenTUI in isolation and fail loudly if it cannot start. Set `CMUX_FEED_TUI_BUN_PATH` to an explicit Bun executable when your shell does not expose Bun on `PATH`. Set `CMUX_FEED_TUI_LEGACY=1` or run `cmux feed tui --legacy` to force the older built-in TUI.

## How it works

```text
┌─────────────────────┐  hook/stdin  ┌──────────────────────────┐
│ Agent CLI           ├─────────────▶│ cmux hooks feed          │
│ (Claude / Codex /…) │              │  forwards to cmux socket │
└─────────────────────┘              └──────────────┬───────────┘
                                                    │
┌─────────────────────┐  plugin in   ┌──────────────┼───────────┐
│ OpenCode            ├─────────────▶│ cmux-feed.js ▼           │
│                     │  process     │ writes same socket       │
└─────────────────────┘              └──────────────┬───────────┘
                                                    │
                              ┌─────────────────────▼────────┐
                              │ feed.push (V2 socket verb)   │
                              │ ─────────────────────────────│
                              │ FeedCoordinator parks the    │
                              │ hook on a semaphore keyed by │
                              │ request_id (up to 120s).     │
                              └─────────────────────┬────────┘
                                                    │
                              ┌─────────────────────▼────────┐
                              │ @MainActor @Observable       │
                              │ WorkstreamStore              │
                              │  ring buffer + JSONL audit   │
                              └─────┬──────────────────┬─────┘
                                    │                  │
                         ┌──────────▼────┐   ┌─────────▼────────┐
                         │ FeedPanelView │   │ UNUserNotification│
                         │ (right sidebar)│   │ (inline actions)  │
                         └───────────────┘   └──────────────────┘
```

Agents pipe their hook events into `cmux hooks feed --source <agent>`. The bridge forwards the event to the cmux socket as a `feed.push` V2 frame. The `FeedCoordinator` records it on the `@MainActor` `WorkstreamStore`, displays it in the sidebar (and posts a native notification if the window isn't focused), then blocks the hook on a semaphore keyed by the event's `request_id`.

When you click Allow / Deny / Submit (either in Feed or in the notification's inline action buttons), `feed.permission.reply` / `feed.question.reply` / `feed.exit_plan.reply` delivers the decision back through `FeedCoordinator`, which wakes the hook. The hook emits the agent's expected decision JSON on stdout and the agent proceeds.

All events (actionable and telemetry) are appended to `~/.cmuxterm/workstream.jsonl` for audit. Memory holds the most recent 2000 items in a ring; older items remain available in the JSONL audit log.

## Installing hooks

```bash
cmux hooks setup
cmux hooks setup --agent codex
cmux hooks uninstall
```

Installs Feed-relevant hooks for every supported CLI whose binary is on `PATH`:

| Agent        | Config                                    | Feed trigger             |
|--------------|-------------------------------------------|--------------------------|
| Claude Code  | wrapper-injected                          | PermissionRequest        |
| Codex        | `~/.codex/hooks.json`                     | PreToolUse               |
| Cursor CLI   | `~/.cursor/hooks.json`                    | beforeShellExecution     |
| Gemini       | `~/.gemini/settings.json`                 | PreToolUse               |
| Copilot      | `~/.copilot/config.json`                  | PreToolUse               |
| CodeBuddy    | `~/.codebuddy/settings.json`              | PreToolUse               |
| Factory      | `~/.factory/settings.json`                | PreToolUse               |
| Qoder        | `~/.qoder/settings.json`                  | PreToolUse               |
| OpenCode     | `~/.config/opencode/plugins/cmux-feed.js` | plugin event bus         |

Individual agents:

```bash
cmux hooks codex install
cmux hooks opencode install               # global
cmux hooks opencode install --project     # .opencode/plugins/cmux-feed.js in cwd
cmux hooks <agent> uninstall
```

Agents without a binary on `PATH` are skipped at install time, and `cmux hooks setup` prints a summary line naming the ones it skipped. Use `cmux hooks setup --agent <name>` to install one integration, or `cmux hooks uninstall --agent <name>` to remove one.

## Decision semantics

**Permission modes**

| Mode   | What cmux sends back to the agent                                             |
|--------|--------------------------------------------------------------------------------|
| Once   | Allow once through the agent's native permission hook.                         |
| Always | Allow and apply the agent's suggested persistent permission rule when present. |
| All tools | Allow and apply the agent's suggested persistent permission rule when present. |
| Bypass | Allow and request session-level bypass mode when the agent supports it.        |
| Deny   | Deny through the agent's native permission hook.                               |

For Claude Code, the cmux wrapper launches Claude with `--allow-dangerously-skip-permissions`. This does not enable bypass by default, but it lets a later `PermissionRequest` response switch the current session into `bypassPermissions`. Without that launch flag, Claude ignores `setMode: bypassPermissions`.

**Plan-mode decisions**

| Mode              | Behavior                                                  |
|-------------------|-----------------------------------------------------------|
| Ultraplan | Reject the local plan and ask Claude to refine it with Ultraplan. |
| Manual    | Allow the plan and keep manual edit approvals.                    |
| Auto      | Allow the plan and request Claude auto mode.                      |
| Deny      | Deny with the user's rejection or feedback message.               |

**AskUserQuestion**

For Claude Code, AskUserQuestion is answered by allowing the PermissionRequest with an updated tool input containing the selected answers. Other agents use their native question reply shape where available.

## Timeout behavior

Feed is advisory, not blocking. The hook waits at most 120 seconds for a user decision. On timeout the bridge emits `{}` (no decision) and the agent falls through to its own in-TUI prompt. This matches Vibe Island's "soft wait" model — it never freezes a workflow forever.

Per-event timeout inside agent hook configs is raised to roughly 120 to 125 seconds for Feed bridge entries (Claude uses 125 seconds for PermissionRequest), so a user taking 30 seconds to approve something does not trip default 5 000 ms hook timeouts.

## Storage

| Path                              | Contents                                                   |
|-----------------------------------|------------------------------------------------------------|
| `~/.cmuxterm/workstream.jsonl`    | Append-only audit log of every Feed event.                 |
| `~/.cmuxterm/<agent>-hook-sessions.json` | Session-to-workspace mapping used by `feed.jump`.   |
| `~/.config/cmux/cmux.sock`        | V2 socket the hooks/plugin talk to.                        |
| `~/.config/opencode/plugins/cmux-feed.js` | OpenCode plugin emitted by `cmux hooks opencode install`. |

To reset history:

```bash
cmux feed clear           # prompts for confirmation
cmux feed clear --yes
```

## Jumping from Feed to the terminal

Double-click a Feed row and cmux focuses the cmux workspace + surface where the agent is running, via `workspace.select` + `surface.focus` V2 verbs. If the agent isn't running in a cmux terminal (no matching entry in `<agent>-hook-sessions.json`), the jump is a no-op.

## Troubleshooting

**Feed shows nothing even though the agent is running.** Check that the hook got installed: `cat ~/.codex/hooks.json` (or similar) should contain a `cmux hooks feed --source codex` entry. Re-run `cmux hooks setup`.

**Agent hangs on a permission request.** Feed never blocks the agent longer than 120 seconds; if you see a longer hang, the hook failed to reach the socket. Verify `$CMUX_SOCKET_PATH` matches the running app (default is `~/.config/cmux/cmux.sock`).

**Notifications aren't showing inline buttons.** The three Feed categories (`CMUXFeedPermission`, `CMUXFeedExitPlan`, `CMUXFeedQuestion`) are registered at app launch. On first Feed use, macOS may prompt for notification authorization; if authorization is denied, Feed rows still appear in the sidebar but no native banner is delivered.

**OpenCode plugin doesn't fire.** Plugin is only installed if `opencode` is on `PATH` at `cmux hooks setup` time. Check `~/.config/opencode/plugins/cmux-feed.js` contains `// cmux-feed-plugin-marker v1`. If you added project-local plugins (`.opencode/plugins/…`), re-run `cmux hooks opencode install --project`.
