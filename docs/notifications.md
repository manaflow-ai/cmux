# Notifications

cmux provides a notification panel for AI agents like Claude Code, Codex, and OpenCode. Notifications appear in a dedicated panel and trigger macOS system notifications.

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

### Claude Code Hooks

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "idle_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "command -v cmux &>/dev/null && cmux notify --title 'Claude Code' --body 'Waiting for input' || osascript -e 'display notification \"Waiting for input\" with title \"Claude Code\"'"
          }
        ]
      },
      {
        "matcher": "permission_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "command -v cmux &>/dev/null && cmux notify --title 'Claude Code' --subtitle 'Permission' --body 'Approval needed' || osascript -e 'display notification \"Approval needed\" with title \"Claude Code\"'"
          }
        ]
      }
    ]
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

### OpenCode

When you launch `opencode` inside a cmux terminal, cmux's bundled `opencode`
wrapper automatically injects a local OpenCode plugin. The sidebar status pill
switches between `Running`, `Retrying`, `Needs input`, `Idle`, and `Error`
based on OpenCode session events, and permission/question/error events create
cmux notifications without any manual setup.

If you prefer a manual setup (or you're running an OpenCode binary outside the
bundled cmux wrapper), create `.opencode/plugins/cmux-notify.js`:

```javascript
export const CmuxNotificationPlugin = async ({ $ }) => ({
  event: async ({ event }) => {
    if (event.type === "session.idle") {
      await $`command -v cmux && cmux notify --title OpenCode --body Session idle`
    }
  },
})
```

## Environment Variables

cmux sets these in child shells:

| Variable | Description |
|----------|-------------|
| `CMUX_SOCKET_PATH` | Path to control socket |
| `CMUX_WORKSPACE_ID` | UUID of the current workspace |
| `CMUX_SURFACE_ID` | UUID of the current surface |
| `CMUX_TAB_ID` | Backward-compatible workspace alias |
| `CMUX_PANEL_ID` | Backward-compatible surface alias |

## CLI Commands

```
cmux notify --title <text> [--subtitle <text>] [--body <text>] [--tab <id|index>] [--panel <id|index>]
cmux list-notifications
cmux clear-notifications
cmux ping
```

## Best Practices

1. **Always check availability first** - Use `command -v cmux` before calling
2. **Provide fallbacks** - Use `|| osascript` for macOS fallback
3. **Keep notifications concise** - Title should be brief, use body for details
