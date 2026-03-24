# AI-Powered Tab & Workspace Naming

cmux automatically names tabs and workspaces based on Claude Code conversation content using AI-generated summaries.

## How it works

Three shell hooks are injected by the `claude` wrapper alongside the existing lifecycle hooks:

### 1. Session Start (`cmux-session-namer.sh`)

On new Claude Code session:
- Sets project directory basename as initial workspace name
- Registers this tab as the "workspace owner" (first session wins)
- Clears naming cache so first response triggers a fresh AI summary

### 2. Stop / Turn End (`cmux-tab-namer.sh`)

After each Claude Code response, spawns `claude -p --model haiku` in a detached background process to generate a 2-5 word summary in the conversation's language. The result is written to a pending file.

The background process unsets `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`, and `CMUX_TAB_ID` before calling `claude -p`, preventing the naming hooks from triggering recursively inside the subprocess.

The pending label is applied in `cmux-rename-namer.sh` (UserPromptSubmit hook), so the tab name updates the moment the user sends their next message — not after waiting for Claude's full response.

Background design avoids:
- Blocking the hook with slow AI calls (~5-10s for Haiku)
- cmux socket errors from detached background processes (socket is only accessible from the hook's foreground process)

### 3. User Prompt Submit (`cmux-rename-namer.sh`)

On every user message:
- Applies any pending AI label from the previous Stop (faster than waiting for Claude's next response)
- If a `/rename` custom title exists in the transcript, syncs it to the tab name and workspace (owner only)
- Writes a marker file so the custom title suppresses AI naming even in long transcripts

## Naming priority

| Priority | Workspace name source | Tab name source |
|----------|----------------------|-----------------|
| 1 (highest) | `/rename` by owner tab | `/rename` custom title |
| 2 | AI summary from owner tab | AI summary (per-tab) |
| 3 (initial) | Project directory basename | (none) |

## Workspace owner model

The first Claude Code session started in a workspace becomes the "owner". Only the owner's AI summary and `/rename` affect the workspace name. Other tabs in the same workspace manage their own tab names independently.

Owner is tracked via `/tmp/cmux-ws-owner-{WORKSPACE_ID}`. This file persists in `/tmp/` until the OS clears it (typically on reboot); it is not removed when sessions end. The first session to start in a workspace wins ownership for the lifetime of that file.

## Custom title behavior

When a user `/rename`s a session:
- The custom title immediately becomes the tab name
- AI auto-naming stops for that tab (detected via `custom-title` entries in the transcript)
- If the tab is the workspace owner, the workspace name also updates to the custom title

## Configuration

Tab naming is enabled by default. To disable it, set:

```bash
export CMUX_TAB_NAMER_DISABLED=1
```

## Cache and temp files

All temporary files are in `/tmp/` and scoped by surface/workspace ID:
- `/tmp/cmux-tab-pending-{SURFACE_ID}` — pending AI label
- `/tmp/cmux-tab-cache-{SURFACE_ID}` — last applied label + line count
- `/tmp/cmux-tab-prompt-{SURFACE_ID}` — prompt file for `claude -p`
- `/tmp/cmux-ws-owner-{WORKSPACE_ID}` — workspace owner surface ID
