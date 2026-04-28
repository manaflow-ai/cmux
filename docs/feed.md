# Feed

Feed is cmux's inline surface for AI agent decisions. It shows three things that need a human response, right in the right sidebar next to Files and Sessions:

- **Permission requests** — Agent wants to run a tool, edit a file, or execute a shell command. Pick Once / Always / All tools / Bypass / Deny.
- **ExitPlanMode** — Agent finished planning and is ready to start editing. Pick Ultraplan / Manual / Auto.
- **AskUserQuestion** — Agent is asking a multiple-choice question. Pick one (or several) and hit Submit.

Anything else the agent does — tool uses, assistant messages, session starts/stops, `TodoWrite` updates — is stored but hidden under the Feed's Actionable / All toggle. The default view only shows what needs your attention.

## How it works

```text
┌─────────────────────┐  hook/stdin  ┌──────────────────────────┐
│ Agent CLI           ├─────────────▶│ cmux feed-hook           │
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

Agents pipe their hook events into `cmux feed-hook --source <agent>`. The bridge forwards the event to the cmux socket as a `feed.push` V2 frame. The `FeedCoordinator` records it on the `@MainActor` `WorkstreamStore`, displays it in the sidebar (and posts a native notification if the window isn't focused), then blocks the hook on a semaphore keyed by the event's `request_id`.

When you click Allow / Deny / Submit (either in Feed or in the notification's inline action buttons), `feed.permission.reply` / `feed.question.reply` / `feed.exit_plan.reply` delivers the decision back through `FeedCoordinator`, which wakes the hook. The hook emits the agent's expected decision JSON on stdout and the agent proceeds.

All events (actionable and telemetry) are appended to `~/.cmuxterm/workstream.jsonl` for audit. Memory holds the most recent 2000 items in a ring; older items remain available in the JSONL audit log.

## Installing hooks

```bash
cmux setup-hooks
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
cmux codex install-hooks
cmux opencode install-hooks               # global
cmux opencode install-hooks --project     # .opencode/plugins/cmux-feed.js in cwd
cmux <agent> uninstall-hooks
```

Agents without a binary on `PATH` are skipped at install time — `cmux setup-hooks` prints a summary line naming the ones it skipped.

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

Per-event timeout inside the agent's hook config is bumped to 120 000 ms specifically for feed-hook entries, so a user taking 30 seconds to approve something doesn't trip the agent's default 5 000 ms timeout.

## Storage

| Path                              | Contents                                                   |
|-----------------------------------|------------------------------------------------------------|
| `~/.cmuxterm/workstream.jsonl`    | Append-only audit log of every Feed event.                 |
| `~/.cmuxterm/<agent>-hook-sessions.json` | Session-to-workspace mapping used by `feed.jump`.   |
| `~/.config/cmux/cmux.sock`        | V2 socket the hooks/plugin talk to.                        |
| `~/.config/opencode/plugins/cmux-feed.js` | OpenCode plugin emitted by `cmux opencode install-hooks`. |

To reset history:

```bash
cmux feed clear           # prompts for confirmation
cmux feed clear --yes
```

## Jumping from Feed to the terminal

Double-click a Feed row and cmux focuses the cmux workspace + surface where the agent is running, via `workspace.select` + `surface.focus` V2 verbs. If the agent isn't running in a cmux terminal (no matching entry in `<agent>-hook-sessions.json`), the jump is a no-op.

## Troubleshooting

**Feed shows nothing even though the agent is running.** Check that the hook got installed: `cat ~/.codex/hooks.json` (or similar) should contain a `cmux feed-hook --source codex` entry. Re-run `cmux setup-hooks`.

**Agent hangs on a permission request.** Feed never blocks the agent longer than 120 seconds; if you see a longer hang, the hook failed to reach the socket. Verify `$CMUX_SOCKET_PATH` matches the running app (default is `~/.config/cmux/cmux.sock`).

**Notifications aren't showing inline buttons.** The three Feed categories (`CMUXFeedPermission`, `CMUXFeedExitPlan`, `CMUXFeedQuestion`) are registered at app launch. On first Feed use, macOS may prompt for notification authorization; if authorization is denied, Feed rows still appear in the sidebar but no native banner is delivered.

**OpenCode plugin doesn't fire.** Plugin is only installed if `opencode` is on `PATH` at `cmux setup-hooks` time. Check `~/.config/opencode/plugins/cmux-feed.js` contains `// cmux-feed-plugin-marker v1`. If you added project-local plugins (`.opencode/plugins/…`), re-run `cmux opencode install-hooks --project`.
