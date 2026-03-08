---
name: cmux-workspace-colors
description: Color-code cmux workspaces and get color-tagged notifications that visually identify their source workspace.
---

# Workspace Colors

Assign custom colors to workspaces for visual organization. Notifications from colored workspaces automatically inherit the workspace color.

## Quick Start

```bash
# Set a workspace color
cmux set-workspace-color "#C0392B"
cmux set-workspace-color --workspace workspace:2 "#1565C0"

# Clear a workspace color
cmux set-workspace-color --clear

# Send a notification (inherits workspace color automatically)
cmux notify --title "Build done" --body "All tests passed"

# Override notification color explicitly
cmux notify --title "Error" --body "Build failed" --color "#C0392B"

# Check workspace colors
cmux list-workspaces --json
```

## How It Works

1. **Workspace color** is set via `set-workspace-color` and persists across sessions.
2. **Notifications** inherit the source workspace's color automatically. The notification dot and left-edge bar in the notifications panel render in the workspace color.
3. An explicit `--color` flag on `cmux notify` overrides the workspace default.

## Color Palette

cmux includes 16 default colors:

| Name | Hex |
|------|-----|
| Red | #C0392B |
| Crimson | #922B21 |
| Orange | #A04000 |
| Amber | #7D6608 |
| Olive | #4A5C18 |
| Green | #196F3D |
| Teal | #006B6B |
| Aqua | #0E6B8C |
| Blue | #1565C0 |
| Navy | #1A5276 |
| Indigo | #283593 |
| Purple | #6A1B9A |
| Magenta | #AD1457 |
| Rose | #880E4F |
| Brown | #7B3F00 |
| Charcoal | #3E4B5E |

Any `#RRGGBB` hex value is accepted.

## Deep-Dive References

| Reference | When to Use |
|-----------|-------------|
| [references/commands.md](references/commands.md) | Full command reference |
