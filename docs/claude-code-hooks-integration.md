# Claude Code Hooks Integration

cmux includes built-in Claude Code integration via `cmux claude-hook`, which manages workspace status indicators (`✳`/`⠂` prefixes) and session lifecycle. This document describes additional Claude Code hooks that enhance the experience with **auto-generated tab names** and **instant `/rename` sync**.

## Overview

cmux natively names workspaces from Claude Code's terminal title (OSC 2). These hooks add two capabilities:

| Hook | Event | Purpose |
|------|-------|---------|
| `cmux-tab-sync.sh` | `Stop` | Auto-summarize session focus → tab name |
| `cmux-rename-sync.sh` | `UserPromptSubmit` | Sync `/rename` → workspace name instantly |
| `cmux-session-start.sh` | `SessionStart` | Reset workspace name for new sessions |

### Why tab names matter

In a workspace with multiple tabs (e.g., one Claude session + helper terminals), all tabs default to mirroring the workspace name. These hooks give each tab a concise, auto-generated summary of its current conversation focus — making it easy to distinguish tabs at a glance.

## Setup

### 1. Install hook scripts

Copy the three scripts to your Claude Code hooks directory:

```bash
mkdir -p ~/.claude/hooks
cp docs/examples/cmux-tab-sync.sh ~/.claude/hooks/
cp docs/examples/cmux-rename-sync.sh ~/.claude/hooks/
cp docs/examples/cmux-session-start.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/cmux-tab-sync.sh
chmod +x ~/.claude/hooks/cmux-rename-sync.sh
chmod +x ~/.claude/hooks/cmux-session-start.sh
```

### 2. Register hooks in Claude Code settings

Add the following to `~/.claude/settings.json` under `"hooks"`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/cmux-rename-sync.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/cmux-tab-sync.sh"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/cmux-session-start.sh"
          }
        ]
      }
    ]
  }
}
```

> **Note:** If you already have hooks configured for these events, add the cmux hooks to the existing arrays.

## How it works

### Tab name auto-summary (`cmux-tab-sync.sh`)

Fires on the `Stop` event (after each Claude response). Reads the session transcript JSONL:

- **First 3 user messages** — captures the session's original goal
- **Last 5 messages** (user + assistant) — captures the current focus

Extracts the most frequent meaningful keywords (2-5 words, mixed Chinese/English), and calls `cmux rename-tab --surface $CMUX_SURFACE_ID`.

Examples of generated tab names:
- `Fix auth bug login` (from "fix the authentication bug in login.py")
- `cmux skill rename` (from a session about building cmux integration)
- `Add unit tests API` (from "add unit tests for the API endpoints")

### `/rename` workspace sync (`cmux-rename-sync.sh`)

Fires on `UserPromptSubmit`. Checks the transcript for `custom-title` entries (written by `/rename`). If found, immediately syncs to `cmux rename-workspace`.

### Session start reset (`cmux-session-start.sh`)

Fires on `SessionStart`. Resets the workspace name to the working directory basename, clearing any stale `/rename` from a previous session. cmux's native OSC 2 integration then takes over with the new session's auto-generated title.

## Architecture

```
Workspace name (sidebar):
  Priority 1: /rename → cmux-rename-sync.sh (UserPromptSubmit) → rename-workspace
  Priority 2: Claude Code auto-title → OSC 2 → cmux native (ghosttyDidSetTitle)
  Priority 3: cwd basename → cmux-session-start.sh (SessionStart)

Tab name (tab bar):
  Always: transcript summary → cmux-tab-sync.sh (Stop) → rename-tab
```

All hooks are guarded by `[ -z "$CMUX_WORKSPACE_ID" ] && exit 0` — they no-op outside cmux.

## Performance

- `cmux-tab-sync.sh`: ~0.35s (reads head/tail of transcript, not full scan)
- `cmux-rename-sync.sh`: ~0.35s (tail + grep for custom-title)
- `cmux-session-start.sh`: ~0.05s (single rename-workspace call)
