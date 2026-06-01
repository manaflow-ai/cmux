# Feed

Feed is cmux's inline surface for AI agent decisions. It stays in the right sidebar on `Ctrl-4`. The keyboard-first OpenTUI Feed can also run in the separate right-sidebar [Dock](dock.md) after you add a Dock control that runs `cmux feed tui`. It shows three things that need a human response:

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
                              │ FeedCoordinator records the  │
                              │ event while the hook process │
                              │ already returned to agent.   │
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

Agents pipe their hook events into `cmux hooks feed --source <agent>`. Most installed hook shims snapshot stdin, start the cmux socket call in the background, and return `{}` to the agent immediately. Claude `PermissionRequest` remains synchronous so Feed Allow/Deny decisions still reach Claude before the tool runs. The bridge forwards the event to the cmux socket as a `feed.push` V2 frame. The `FeedCoordinator` records it on the `@MainActor` `WorkstreamStore`, displays it in the sidebar, and posts a native notification if the window isn't focused.

When you click Allow / Deny / Submit (either in Feed or in the notification's inline action buttons), `feed.permission.reply` / `feed.question.reply` / `feed.exit_plan.reply` delivers the decision back through `FeedCoordinator`. Integrations with an async reply channel can still apply the decision in the background. Other agents fall through to their native prompt without waiting on cmux.

All events (actionable and telemetry) are appended to `~/.cmuxterm/workstream.jsonl` for audit. Memory holds the most recent 2000 items in a ring; older items remain available in the JSONL audit log.

The reconnectable [events stream](events.md) also publishes Feed and agent-hook
activity as it happens:

```bash
cmux events --category feed --category agent --cursor-file ~/.cache/cmux/feed-events.seq --reconnect
```

Use `feed.item.received` to observe incoming hook work, `feed.item.completed`
to observe the eventual hook result, and `agent.hook.<HookEventName>` to consume
Claude Code, Codex, OpenCode, and other agent events by their native hook name.

## Installing hooks

```bash
cmux hooks setup
cmux hooks setup --agent codex
cmux hooks setup rovo
cmux hooks uninstall
cmux hooks uninstall rovo
```

Installs supported agent hooks whose binaries are on `PATH`. See [Agent hook integrations](agent-hooks.md) for the complete session restore and Feed support matrix.

| Agent        | Config                                    | Feed trigger             |
|--------------|-------------------------------------------|--------------------------|
| Claude Code  | wrapper-injected                          | PermissionRequest        |
| Codex        | `~/.codex/hooks.json`                     | PermissionRequest        |
| Grok         | `~/.grok/hooks/cmux-session.json`         | PreToolUse               |
| OpenCode     | `~/.config/opencode/plugins/cmux-feed.js` | plugin event bus         |
| Cursor CLI   | `~/.cursor/hooks.json`                    | beforeShellExecution     |
| Gemini       | `~/.gemini/settings.json`                 | PreToolUse               |
| Copilot      | `~/.copilot/config.json`                  | PreToolUse               |
| CodeBuddy    | `~/.codebuddy/settings.json`              | PreToolUse               |
| Factory      | `~/.factory/settings.json`                | PreToolUse               |
| Qoder        | `~/.qoder/settings.json`                  | PreToolUse               |
| Pi           | `~/.pi/agent/extensions/cmux-session.ts`  | lifecycle only           |
| Rovo Dev     | `~/.rovodev/config.yml`                   | lifecycle only           |

Individual agents:

```bash
cmux hooks codex install
cmux hooks opencode install               # global
cmux hooks opencode install --project     # .opencode/plugins/cmux-feed.js in cwd
cmux hooks <agent> uninstall
```

Agents without a binary on `PATH` are skipped at install time, and `cmux hooks setup` prints a summary line naming the ones it skipped. Use `cmux hooks setup --agent <name>` or `cmux hooks setup <name>` to install one integration, and `cmux hooks uninstall --agent <name>` or `cmux hooks uninstall <name>` to remove one. Rovo Dev accepts either `rovodev` or `rovo`.

## Decision semantics

**Permission modes**

| Mode   | What cmux sends back to the agent                                             |
|--------|--------------------------------------------------------------------------------|
| Once   | Allow once when the integration exposes an async reply channel.                |
| Always | Allow and apply the agent's suggested persistent permission rule when present. |
| All tools | Allow and apply the agent's suggested persistent permission rule when present. |
| Bypass | Allow and request session-level bypass mode when the agent supports it.        |
| Deny   | Deny when the integration exposes an async reply channel.                      |

For agents without an async reply channel, Feed records the request and the agent's own prompt remains the authoritative decision point.

**Plan-mode decisions**

| Mode              | Behavior                                                  |
|-------------------|-----------------------------------------------------------|
| Ultraplan | Reject the local plan and ask Claude to refine it with Ultraplan. |
| Manual    | Allow the plan and keep manual edit approvals.                    |
| Auto      | Allow the plan and request Claude auto mode.                      |
| Deny      | Deny with the user's rejection or feedback message.               |

**AskUserQuestion**

Agents with async question reply APIs can receive Feed answers in the background. Other agents keep their native question prompt.

Codex's `request_user_input` and `update_plan` currently surface through its app-server request/notification path, not through command hooks. A stock `codex` TUI running in a cmux terminal keeps those frames inside Codex's in-process app-server client, so its plan-mode questions still fall back to Codex's own TUI. cmux can route Codex permission approvals through `PermissionRequest`; showing Codex plan questions in Feed would require launching Codex against a shared standalone app server and adding a Codex app-server Feed adapter, or upstream Codex hook coverage for those frames.

## Timeout behavior

Feed is advisory for most agents, not blocking. Installed cmux hooks usually return immediately with `{}` and keep socket work in a background process, so an unavailable or slow app does not hold up the agent. Claude `PermissionRequest` stays blocking because Claude has no separate async approval reply channel.

Per-event timeouts inside agent hook configs are small watchdogs for the shell handoff, usually 1 to 5 seconds. Claude `PermissionRequest` is the exception: it keeps the longer blocking timeout because that hook is Claude's decision channel. Other user decisions happen through Feed or the agent's native fallback prompt after the hook has already resolved.

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

**Codex plan-mode question stays in the terminal.** Codex `request_user_input` is not a hook event in the stock TUI path. Feed only sees Codex permission hooks today.

**Agent hangs on a permission request.** Feed hooks return immediately. If the agent still hangs, it is likely waiting on its own native prompt or a non-cmux hook. Verify `$CMUX_SOCKET_PATH` matches the running app (default is `~/.config/cmux/cmux.sock`) if Feed rows are missing.

**Notifications aren't showing inline buttons.** The three Feed categories (`CMUXFeedPermission`, `CMUXFeedExitPlan`, `CMUXFeedQuestion`) are registered at app launch. On first Feed use, macOS may prompt for notification authorization; if authorization is denied, Feed rows still appear in the sidebar but no native banner is delivered.

**OpenCode plugin doesn't fire.** Plugin is only installed if `opencode` is on `PATH` at `cmux hooks setup` time. Check `~/.config/opencode/plugins/cmux-feed.js` contains `// cmux-feed-plugin-marker v1`. If you added project-local plugins (`.opencode/plugins/…`), re-run `cmux hooks opencode install --project`.
