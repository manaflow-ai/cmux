# Notifications

cmux provides a notification panel for AI agents like Claude Code, Codex, and OpenCode. Desktop notifications can use macOS Notification Center or an interactive Dynamic Notch panel.

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

# Notify a specific workspace/surface
cmux notify --title "Done" --workspace workspace:1 --surface surface:1

# Force an interactive notch and wait for the selected action id
choice=$(cmux notify --delivery notch --title "Deploy?" \
  --action deploy=Deploy --action cancel=Cancel --wait)
```

## Dynamic Notch

Set `notifications.delivery` to `dynamicNotch` in `~/.config/cmux/cmux.json`, or choose Dynamic Notch under Settings > App > Notification Delivery. The panel is independent of macOS Notification Center, so Focus and Do Not Disturb do not suppress it.

Dynamic Notch notifications accumulate in a compact tray instead of replacing one another. The tray shows the pending count, expands into a newest-first scrollable list while hovered, and collapses when the pointer leaves or Escape is pressed. Each button, dismissal, or timeout resolves only its own row.

`cmux notify --delivery notch` overrides the setting for one notification. `--icon` accepts an SF Symbol name, repeated `--action id=Label` flags add up to four buttons, and `--input id=Label` or `--secure-input id=Label` add runtime-defined fields. IDs must be unique ASCII strings containing only letters, numbers, `.`, `_`, or `-`. `--timeout` controls dismissal. `--wait` prints the selected action id when no fields exist, and prints JSON containing `action`, `notification_id`, and `values` when the form has fields. cmux never executes action payloads as shell commands.

### Appearance

Use Settings > App > Dynamic Notch Appearance, or set global values under `notifications.dynamicNotch`:

```jsonc
{
  "notifications": {
    "delivery": "dynamicNotch",
    "dynamicNotch": {
      "expandedWidth": 560,
      "maximumExpandedHeight": 640,
      "rowHorizontalPadding": 22,
      "accentColor": "#0A84FF",
      "shellBackgroundColor": "#111318",
      "shellBackgroundOpacity": 0.96,
      "showScrollIndicators": false
    }
  }
}
```

Override any value for one notification with repeated `--style key=value` flags:

```bash
cmux notify --delivery notch --title "Approval needed" \
  --style expandedWidth=620 \
  --style rowHorizontalPadding=24 \
  --style accentColor=#FF9F0A
```

The JSON form API accepts the same keys under `appearance`:

```json
{
  "version": 1,
  "title": "Approve deployment?",
  "appearance": {
    "expandedWidth": 620,
    "accentColor": "#FF9F0A",
    "bodyLineLimit": 8
  }
}
```

Precedence is global `cmux.json`, then the form's `appearance`, then direct `--style` flags. Direct flags win when a key appears more than once. Each accumulated row retains its own text, input, row, and action styling. The newest pending notification controls tray-wide dimensions, shell chrome, and compact styling. Removing it restores the next row's tray-wide values.

Colors accept `system`, `null` in JSON, or `#RRGGBB`. `system` and `null` use the native semantic color for that role. Every numeric value is range-checked. Unknown keys, invalid colors, non-finite numbers, and out-of-range values reject the notification before display.

Available tokens:

- Layout: `compactWidth`, `compactHeight`, `syntheticNotchWidth`, `expandedWidth`, `maximumExpandedHeight`, `shellPadding`, `floatingOuterPadding`, `compactHorizontalPadding`, `compactVerticalPadding`, `rowHorizontalPadding`, `rowTopPadding`, `rowBottomPadding`, `dividerHorizontalPadding`, `floatingCornerRadius`, `notchTopCornerRadius`, `notchBottomCornerRadius`, `rowCornerRadius`, `compactCornerRadius`, `inputCornerRadius`, `inputHorizontalPadding`, `inputVerticalPadding`, `compactIconSize`, `notificationIconSize`, `notificationIconFrame`, `shellBorderWidth`, `inputBorderWidth`.

- Spacing: `compactSpacing`, `rowSpacing`, `headerSpacing`, `textSpacing`, `inputSpacing`, `inputLabelSpacing`, `actionSpacing`.

- Colors: `shellBackgroundColor`, `shellBorderColor`, `shadowColor`, `primaryTextColor`, `secondaryTextColor`, `accentColor`, `dividerColor`, `rowBackgroundColor`, `compactBackgroundColor`, `compactTextColor`, `compactIconColor`, `closeButtonColor`, `inputBackgroundColor`, `inputTextColor`, `inputBorderColor`.

- Behavior: `animationDuration`, `arrivalRevealDuration`, `shellBackgroundOpacity`, `shadowOpacity`, `shadowRadius`, `hoverShadowOpacity`, `hoverShadowRadius`, `rowBackgroundOpacity`, `compactBackgroundOpacity`, `inputBackgroundOpacity`, `titleLineLimit`, `subtitleLineLimit`, `bodyLineLimit`, `showScrollIndicators`, `pointerRevealDistance`, `retractWhenPointerLeaves`.

On a display without a physical notch, cmux draws a synthetic notch inside the menu-bar band. New arrivals show the compact pill for `arrivalRevealDuration` seconds, with rapid arrivals resetting that interval on the same panel. It then retracts to the plain notch silhouette while the pointer is away and expands the accumulated tray only when the pointer enters the hardware or synthetic notch. This direct-hover behavior applies independently to every display, including large notchless monitors. Set `pointerRevealDistance` above its default of `0` to add an approach margin around each notch, or set `retractWhenPointerLeaves` to `false` to keep the pending count visible. Shadows are disabled by default; `shadowOpacity`, `hoverShadowOpacity`, their radii, and `shadowColor` can restore a custom shadow. Menu-bar height falls back to the system status-bar thickness when macOS auto-hides the menu bar.

Run `cmux notify --print-schema` for exact types, ranges, and defaults. The command works without a running cmux instance, which lets agents validate and generate forms before connecting.

Agents can pass the complete form with `--spec '<json>'`, `--spec @path`, or `--spec -` for stdin:

```json
{
  "version": 1,
  "title": "Approve deployment?",
  "body": "Production will restart.",
  "icon": "shippingbox.fill",
  "timeout": 300,
  "appearance": {
    "expandedWidth": 620,
    "accentColor": "#0A84FF"
  },
  "actions": [
    { "id": "approve", "label": "Approve" },
    { "id": "deny", "label": "Deny" }
  ],
  "inputs": [
    {
      "id": "reason",
      "label": "Reason",
      "placeholder": "Optional note",
      "value": "",
      "secure": false
    }
  ]
}
```

`cmux notify --print-schema` prints the versioned JSON Schema without connecting to a running app. Unknown keys and invalid types are rejected. Scalar command-line flags and repeated `--style` values override the spec, while repeated `--action`, `--input`, and `--secure-input` values are appended. Custom actions replace the built-in Open button.

Explicit delivery overrides and interactive forms require a local cmux socket. A relayed Cloud VM CLI can still send ordinary notifications, which use the Mac's configured delivery mode.

```bash
response=$(cmux notify --spec @approval.json --wait --json)
action=$(printf '%s' "$response" | jq -r .action)
reason=$(printf '%s' "$response" | jq -r .values.reason)
```

The response action is a caller-defined action id, `open`, `dismiss`, `timeout`, `replaced`, or `dismissed`. `replaced` means a newer notification from the same workspace surface atomically replaced that row. Callers should treat every value except their accepted action ids as cancellation.

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
cmux notify --title <text> [--subtitle <text>] [--body <text>] [--delivery default|system|notch] [--icon <sf-symbol>] [--action <id=Label>] [--input <id=Label>] [--secure-input <id=Label>] [--spec <json|@file|->] [--wait] [--json] [--timeout <seconds>] [--workspace <id|ref>] [--surface <id|ref>]
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
