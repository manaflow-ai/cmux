# Notifications

cmux provides a notification panel for AI agents like Claude Code, Codex, and OpenCode. Notifications appear in a dedicated panel and trigger macOS system notifications.

> For inline permission / plan / question approvals directly from the sidebar (Vibe Island-style), see **[Feed](feed.md)**. `cmux hooks setup` installs the Feed bridge alongside the notification hooks covered below.

## Quick Start

```bash
# Send a notification (if cmux is available)
command -v cmux &>/dev/null && cmux notify --title "Done" --body "Task complete"

# With fallback to macOS notifications
command -v cmux &>/dev/null && cmux notify --title "Done" --body "Task complete" || osascript -e 'display notification "Task complete" with title "Done"'
```

## Detection

Check if `cmux` CLI is available before using it:

```bash
# Shell
if command -v cmux &>/dev/null; then
    cmux notify --title "Hello"
fi

# One-liner with fallback
command -v cmux &>/dev/null && cmux notify --title "Hello" || osascript -e 'display notification "" with title "Hello"'
```

```python
# Python
import shutil
import subprocess

def notify(title: str, body: str = ""):
    if shutil.which("cmux"):
        subprocess.run(["cmux", "notify", "--title", title, "--body", body])
    else:
        # Fallback to macOS
        subprocess.run(["osascript", "-e", f'display notification "{body}" with title "{title}"'])
```

## CLI Usage

```bash
# Simple notification
cmux notify --title "Build Complete"

# With subtitle and body
cmux notify --title "Claude Code" --subtitle "Permission" --body "Approval needed"

# Notify specific tab/panel
cmux notify --title "Done" --tab 0 --panel 1
```

## Navigation

Use `Cmd+Shift+U` to jump to the latest unread notification. Use `Ctrl+Cmd+U` to mark the current item as oldest unread and jump to the next latest unread. Both shortcuts are configurable in Settings > Keyboard Shortcuts and in `~/.config/cmux/cmux.json`.

## Suppress only the focused surface

By default cmux withdraws a delivered banner when its workspace becomes visible/active, which can retract a banner for a non-focused surface (e.g. a second agent in the same visible workspace) before you notice it. Set the opt-in flag below to `true` so the auto-withdraw fires **only** for the exact focused surface — matching the delivery gate. A banner for a non-focused surface then stays up until you focus that surface (or click/dismiss it). Workspace-visible-but-not-focused surfaces and surfaces in non-visible workspaces keep their banners; explicit "mark workspace read" and clicking/typing still clear notifications as before.

```jsonc
{
  "notifications": {
    // Default: false (legacy workspace-visibility withdraw).
    // Set to true to auto-withdraw only the exact focused surface.
    "suppressOnlyFocusedSurface": true
  }
}
```

## Notification Hooks

`cmux.json` can define composable hooks that receive every notification policy as JSON on stdin and return updated JSON on stdout. Hooks are off by default; cmux only runs them when `notifications.hooks` contains at least one enabled hook. Hooks can filter native banners, sidebar history, sounds, custom commands, workspace reordering, and pane flashes.

```json
{
  "notifications": {
    "hooks": [
      {
        "id": "agent-filter",
        "command": "sed 's/\"desktop\":true/\"desktop\":false/'",
        "timeoutSeconds": 20
      }
    ]
  }
}
```

Hook input and output use this shape:

```json
{
  "version": 1,
  "notification": {
    "workspaceId": "3B3F0D83-...",
    "surfaceId": "7E9C1A02-...",
    "title": "Codex",
    "subtitle": "Waiting",
    "body": "Agent needs input"
  },
  "context": {
    "cwd": "/path/to/project",
    "configPath": "/path/to/project/.cmux/cmux.json",
    "hookId": "agent-filter",
    "appFocused": false,
    "focusedPanel": false
  },
  "effects": {
    "record": true,
    "markUnread": true,
    "reorderWorkspace": true,
    "desktop": true,
    "sound": true,
    "command": true,
    "paneFlash": true
  }
}
```

Global hooks from `~/.config/cmux/cmux.json` run first. Project hooks from parent directories to the current workspace append after that. Project hooks use the same trust prompt as other project `cmux.json` commands before they run. Feed approval banners also pass through these hooks; disabling `desktop` suppresses the native banner while keeping the Feed item available in cmux. Set `"hooksMode": "replace"` in a project `notifications` section to ignore inherited hooks. If any hook fails, times out, or returns invalid JSON, cmux uses the default notification behavior and posts a hook failure alert.

## Integration Examples

### Claude Code

See the [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code) for hook configuration.

### GitHub Copilot CLI

Copilot CLI supports [hooks](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/coding-agent/use-hooks) that run shell commands at key lifecycle events. Add to `~/.copilot/config.json`:

```json
{
  "hooks": {
    "userPromptSubmitted": [
      {
        "type": "command",
        "bash": "if command -v cmux &>/dev/null; then cmux set-status copilot_cli Running; fi",
        "timeoutSec": 3
      }
    ],
    "agentStop": [
      {
        "type": "command",
        "bash": "if command -v cmux &>/dev/null; then cmux notify --title 'Copilot CLI' --body 'Done'; cmux set-status copilot_cli Idle; else osascript -e 'display notification \"Done\" with title \"Copilot CLI\"'; fi",
        "timeoutSec": 5
      }
    ],
    "errorOccurred": [
      {
        "type": "command",
        "bash": "if command -v cmux &>/dev/null; then cmux notify --title 'Copilot CLI' --subtitle 'Error' --body \"$(cat | jq -r '.errorMessage // \"An error occurred\"' 2>/dev/null | head -c 100)\"; cmux set-status copilot_cli Error; else osascript -e 'display notification \"An error occurred\" with title \"Copilot CLI\"'; fi",
        "timeoutSec": 5
      }
    ],
    "sessionEnd": [
      {
        "type": "command",
        "bash": "if command -v cmux &>/dev/null; then cmux clear-status copilot_cli; fi",
        "timeoutSec": 3
      }
    ]
  }
}
```

Or for repo-level hooks, create `.github/hooks/notify.json`:

```json
{
  "version": 1,
  "hooks": {
    "userPromptSubmitted": [ ... ],
    "agentStop": [ ... ]
  }
}
```

### OpenAI Codex

Add to `~/.codex/config.toml`:

```toml
notify = ["bash", "-c", "command -v cmux &>/dev/null && cmux notify --title Codex --body \"$(echo $1 | jq -r '.\"last-assistant-message\" // \"Turn complete\"' 2>/dev/null | head -c 100)\" || osascript -e 'display notification \"Turn complete\" with title \"Codex\"'", "--"]
```

Or create a simple script `~/.local/bin/codex-notify.sh`:

```bash
#!/bin/bash
MSG=$(echo "$1" | jq -r '."last-assistant-message" // "Turn complete"' 2>/dev/null | head -c 100)
command -v cmux &>/dev/null && cmux notify --title "Codex" --body "$MSG" || osascript -e "display notification \"$MSG\" with title \"Codex\""
```

Then use:
```toml
notify = ["bash", "~/.local/bin/codex-notify.sh"]
```

### OpenCode Plugin

The easiest way to get full cmux integration in OpenCode is via the
[`opencode-cmux`](https://www.npmjs.com/package/opencode-cmux) npm package.

Add to `~/.config/opencode/opencode.json`:

```json
{
  "plugin": ["opencode-cmux"]
}
```

OpenCode will download the package automatically on next start. This covers all events
out of the box: session status (busy/idle/error), subagent detection, permission requests,
and question prompts — with sidebar status pills and desktop notifications.

#### What it does

| Event | cmux action |
|---|---|
| Session starts working | Sidebar status: "working" (amber, terminal icon) |
| Session completes (primary) | Desktop notification + log + clear status |
| Session completes (subagent) | Log only — no notification spam |
| Session error | Desktop notification + log + clear status |
| Permission requested | Desktop notification + sidebar status: "waiting" (red) |
| AI has a question (`ask` tool) | Desktop notification + sidebar status: "question" (purple) |

#### Inline plugin (for customization)

If you prefer to inline the plugin or customize the behavior, create
`~/.config/opencode/plugins/cmux.js`:

```javascript
import { existsSync } from "node:fs";

function isInCmux() {
  return (
    existsSync(process.env.CMUX_SOCKET_PATH ?? "/tmp/cmux.sock") ||
    !!process.env.CMUX_WORKSPACE_ID
  );
}

async function notify($, opts) {
  if (!isInCmux()) return;
  try {
    const args = ["--title", opts.title];
    if (opts.subtitle) args.push("--subtitle", opts.subtitle);
    if (opts.body) args.push("--body", opts.body);
    await $`cmux notify ${args}`.quiet().nothrow();
  } catch {}
}

async function setStatus($, key, text, opts) {
  if (!isInCmux()) return;
  try {
    const args = [key, text];
    if (opts?.icon) args.push("--icon", opts.icon);
    if (opts?.color) args.push("--color", opts.color);
    await $`cmux set-status ${args}`.quiet().nothrow();
  } catch {}
}

async function clearStatus($, key) {
  if (!isInCmux()) return;
  try {
    await $`cmux clear-status ${key}`.quiet().nothrow();
  } catch {}
}

async function log($, message, opts) {
  if (!isInCmux()) return;
  try {
    const args = [];
    if (opts?.level) args.push("--level", opts.level === "warn" ? "warning" : opts.level);
    if (opts?.source) args.push("--source", opts.source);
    args.push("--", message);
    await $`cmux log ${args}`.quiet().nothrow();
  } catch {}
}

export default async ({ client, $ }) => {
  async function fetchSession(sessionID) {
    try {
      const result = await client.session.get({ path: { id: sessionID } });
      return result.data ?? null;
    } catch {
      return null;
    }
  }

  return {
    async event({ event }) {
      if (event.type === "session.status") {
        const { sessionID, status } = event.properties;

        if (status.type === "busy") {
          await setStatus($, "opencode", "working", { icon: "terminal", color: "#f59e0b" });
          return;
        }

        if (status.type === "idle") {
          const session = await fetchSession(sessionID);
          const title = session?.title ?? sessionID;

          if (!session?.parentID) {
            // Primary session — notify + clear status
            await notify($, { title: `Done: ${title}` });
            await log($, `Done: ${title}`, { level: "success", source: "opencode" });
            await clearStatus($, "opencode");
          } else {
            // Subagent — log only to avoid notification spam
            await log($, `Subagent finished: ${title}`, { level: "info", source: "opencode" });
          }
          return;
        }
      }

      if (event.type === "session.error") {
        const sessionID = event.properties.sessionID;
        const session = sessionID ? await fetchSession(sessionID) : null;
        const title = session?.title ?? sessionID ?? "unknown session";

        await notify($, { title: `Error: ${title}` });
        await log($, `Error in session: ${title}`, { level: "error", source: "opencode" });
        await clearStatus($, "opencode");
      }
    },

    async "permission.ask"(input) {
      await notify($, { title: "Needs your permission", subtitle: input.title });
      await setStatus($, "opencode", "waiting", { icon: "lock", color: "#ef4444" });
    },

    async "tool.execute.before"(input) {
      if (input.tool === "ask") {
        await notify($, { title: "Has a question" });
        await setStatus($, "opencode", "question", { icon: "help-circle", color: "#a855f7" });
      }
    },
  };
};
```

## Environment Variables

cmux sets these in child shells:

| Variable | Description |
|----------|-------------|
| `CMUX_SOCKET_PATH` | Path to control socket |
| `CMUX_WORKSPACE_ID` | UUID of the current workspace |
| `CMUX_SURFACE_ID` | UUID of the current surface/panel |
| `CMUX_TAB_ID` | UUID of the current tab (legacy name for `CMUX_WORKSPACE_ID`) |
| `CMUX_PANEL_ID` | UUID of the current panel (legacy name for `CMUX_SURFACE_ID`) |

## CLI Commands

```
cmux notify --title <text> [--subtitle <text>] [--body <text>] [--tab <id|index>] [--panel <id|index>]
cmux set-status <key> <text> [--icon <name>] [--color <#hex>]
cmux clear-status <key>
cmux log <message> [--level info|success|error|warning] [--source <name>]
cmux list-notifications
cmux dismiss-notification (--id <notification-id> | --all-read)
cmux mark-notification-read (--id <notification-id> | --workspace <id|ref> [--surface <id|ref>] | --all)
cmux open-notification --id <notification-id>
cmux jump-to-unread
cmux clear-notifications
cmux set-status <key> <value>
cmux clear-status <key>
cmux ping
```

## Best Practices

1. **Always check availability first** - Use `command -v cmux` before calling, or check `CMUX_WORKSPACE_ID`
2. **Provide fallbacks** - Use `|| osascript` for macOS fallback
3. **Keep notifications concise** - Title should be brief, use body for details
