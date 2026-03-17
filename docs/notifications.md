# Notifications

cmux provides a notification panel for AI agents like Claude Code, Cursor, Codex, and OpenCode. Notifications appear in a dedicated panel and trigger macOS system notifications.

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

## Integration Examples

### Claude Code

See the [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code) for hook configuration.

### Cursor

Cursor supports [hooks](https://docs.cursor.com/context/hooks) that run shell commands at key lifecycle events.

**1. Create the notification script** at `~/.cursor/hooks/cmux-notify.sh`:

```bash
#!/usr/bin/env bash
# ~/.cursor/hooks/cmux-notify.sh
# Requires: jq (brew install jq)

set -euo pipefail
event=$(jq -r '.event' 2>/dev/null || echo "unknown")

case "$event" in
  stop|subagentStop)
    if command -v cmux &>/dev/null; then
      cmux notify --title "Cursor" --body "Agent finished"
    else
      osascript -e 'display notification "Agent finished" with title "Cursor"'
    fi
    ;;
esac
```

**2. Make it executable:**

```bash
chmod +x ~/.cursor/hooks/cmux-notify.sh
```

**3. Add hook configuration** to `~/.cursor/hooks.json`:

```json
{
  "stop": {
    "command": "$HOME/.cursor/hooks/cmux-notify.sh"
  },
  "subagentStop": {
    "command": "$HOME/.cursor/hooks/cmux-notify.sh"
  }
}
```

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

### Cursor Hooks

Cursor supports [hooks](https://cursor.com/docs/hooks) that run shell scripts at key points in the agent lifecycle. Create a notification script and register it in Cursor's hooks config.

> **Note:** The script uses `jq` to parse JSON. Install it via `brew install jq` (macOS) or your package manager.

Create `~/.cursor/hooks/cmux-notify.sh`:

```bash
#!/bin/bash
command -v cmux &>/dev/null || exit 0

EVENT=$(cat)
STATUS=$(echo "$EVENT" | jq -r '.status // ""')
MODEL=$(echo "$EVENT" | jq -r '.model // ""')
SUBAGENT_TYPE=$(echo "$EVENT" | jq -r '.subagent_type // ""')

if [ -n "$SUBAGENT_TYPE" ]; then
    DESC=$(echo "$EVENT" | jq -r '.description // .task // ""' | head -c 80)
    case "$STATUS" in
        completed) cmux notify --title "Cursor" --subtitle "SubAgent" --body "Complete: $DESC" ;;
        error)     cmux notify --title "Cursor" --subtitle "SubAgent" --body "Error: $DESC" ;;
    esac
else
    case "$STATUS" in
        completed) cmux notify --title "Cursor" --body "Agent complete ($MODEL)" ;;
        error)     cmux notify --title "Cursor" --body "Agent error ($MODEL)" ;;
        aborted)   cmux notify --title "Cursor" --body "Agent aborted ($MODEL)" ;;
    esac
fi
exit 0
```

```bash
chmod +x ~/.cursor/hooks/cmux-notify.sh
```

Add to `~/.cursor/hooks.json`:

```json
{
  "version": 1,
  "hooks": {
    "stop": [
      {
        "command": "$HOME/.cursor/hooks/cmux-notify.sh",
        "timeout": 5
      }
    ],
    "subagentStop": [
      {
        "command": "$HOME/.cursor/hooks/cmux-notify.sh",
        "timeout": 5
      }
    ]
  }
}
```

Cursor watches `hooks.json` for changes — no restart needed.

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
cmux clear-notifications
cmux set-status <key> <value>
cmux clear-status <key>
cmux ping
```

## Best Practices

1. **Always check availability first** - Use `command -v cmux` before calling
2. **Provide fallbacks** - Use `|| osascript` for macOS fallback
3. **Keep notifications concise** - Title should be brief, use body for details
