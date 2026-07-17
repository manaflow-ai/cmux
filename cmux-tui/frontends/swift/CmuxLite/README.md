# cmux-lite Swift frontend

`cmux-lite` is a dark native AppKit frontend for a cmux-tui protocol-v7+ session. It renders the selected screen's full split tree from server-rendered styled rows and keeps one render attachment per visible terminal pane.

Wheel or trackpad scrolling enters a bounded styled-history view. Input or the localized Back to live control returns to the current viewport.

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
