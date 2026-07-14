# cmux-lite Swift frontend

`cmux-lite` is a dark AppKit/GhosttyKit frontend for a cmux-tui protocol-v6+ session. It renders the selected screen's full split tree and keeps one byte attachment per visible terminal pane.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| Command-D | Split the active pane right |
| Command-Shift-D | Split the active pane down |
| Command-T | Create a tab in the active pane |
| Command-W | Close the active tab; the last tab closes its pane |
| Command-N | Create a workspace |
| Command-1…9 | Select tab 1…9 in the active pane |
| Control-1…9 | Select screen 1…9 |
| Command-Option-Arrow | Focus the neighboring pane using local layout geometry |
| Command-Control-Arrow | Nudge the matching split ratio by 0.05 |

Shortcuts use one shared action table. Unmatched keys continue to the focused terminal.
