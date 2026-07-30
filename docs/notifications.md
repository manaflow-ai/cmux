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

### AI Suppression Hook

Use a notification hook when you want an agent to decide whether a notification is ready for user action. The hook receives the notification envelope on stdin. Return a partial JSON patch on stdout. Return nothing to keep the notification unchanged.

To suppress only the macOS banner and sound while keeping the notification in cmux:

```json
{
  "effects": {
    "desktop": false,
    "sound": false
  }
}
```

To suppress every visible effect and stop later hooks:

```json
{
  "effects": {
    "record": false,
    "markUnread": false,
    "reorderWorkspace": false,
    "desktop": false,
    "sound": false,
    "command": false,
    "paneFlash": false
  },
  "stop": true
}
```

Example `~/.local/bin/cmux-codex-notification-filter.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

input="$(cat)"

if [[ "${CMUX_CODEX_HOOKS_DISABLED:-}" == "1" ]]; then
  exit 0
fi

command -v codex >/dev/null || exit 0
command -v jq >/dev/null || exit 0

prompt="$(jq -r '
  "Decide whether this cmux notification should be suppressed.\n" +
  "Suppress it unless the user can take action now.\n" +
  "Reply with only one JSON object: {\"suppress\":true} or {\"suppress\":false}.\n\n" +
  "title: " + (.notification.title // "") + "\n" +
  "subtitle: " + (.notification.subtitle // "") + "\n" +
  "body: " + (.notification.body // "")
' <<<"$input")"

output_file="$(mktemp "${TMPDIR:-/tmp}/cmux-codex-notification-filter.XXXXXX")"
trap 'rm -f "$output_file"' EXIT

if ! CMUX_CODEX_HOOKS_DISABLED=1 codex exec \
  -c default_tools_enabled=false \
  -c tools={} \
  -c mcp_servers={} \
  -c web_search=false \
  -c approval_policy=never \
  -c shell_environment_policy.inherit=none \
  --skip-git-repo-check \
  --ephemeral \
  --ignore-user-config \
  --ignore-rules \
  --sandbox read-only \
  --output-last-message "$output_file" \
  - <<<"$prompt" >/dev/null; then
  exit 0
fi

answer="$(cat "$output_file")"

if jq -e '.suppress == true' >/dev/null 2>&1 <<<"$answer"; then
  jq -cn '{
    effects: {
      record: false,
      markUnread: false,
      reorderWorkspace: false,
      desktop: false,
      sound: false,
      command: false,
      paneFlash: false
    },
    stop: true
  }'
fi
```

Then add it to `~/.config/cmux/cmux.json`:

```json
{
  "notifications": {
    "hooks": [
      {
        "id": "codex-actionability-filter",
        "command": "~/.local/bin/cmux-codex-notification-filter.sh",
        "timeoutSeconds": 20
      }
    ]
  }
}
```

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

Create `.opencode/plugins/cmux-notify.js`:

```javascript
export const CmuxNotificationPlugin = async ({ $, }) => {
  const notify = async (title, body) => {
    try {
      await $`command -v cmux && cmux notify --title ${title} --body ${body}`;
    } catch {
      await $`osascript -e ${"display notification \"" + body + "\" with title \"" + title + "\""}`;
    }
  };

  return {
    event: async ({ event }) => {
      if (event.type === "session.idle") {
        await notify("OpenCode", "Session idle");
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
| `CMUX_TAB_ID` | UUID of the current tab |
| `CMUX_PANEL_ID` | UUID of the current panel |

## CLI Commands

```
cmux notify --title <text> [--subtitle <text>] [--body <text>] [--tab <id|index>] [--panel <id|index>]
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

1. **Always check availability first** - Use `command -v cmux` before calling
2. **Provide fallbacks** - Use `|| osascript` for macOS fallback
3. **Keep notifications concise** - Title should be brief, use body for details
