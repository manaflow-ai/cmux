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
cmux clear-notifications
cmux ping
```

## Best Practices

1. **Always check availability first** - Use `command -v cmux` before calling, or check `CMUX_WORKSPACE_ID`
2. **Provide fallbacks** - Use `|| osascript` for macOS fallback
3. **Keep notifications concise** - Title should be brief, use body for details
