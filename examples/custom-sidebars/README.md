# Custom sidebar examples (`cmux.sidebar/1`)

Each file replaces the workspace list. To use one:

1. Copy `cmux-app.json` to `~/.config/cmux/customize/`.
2. Copy one example there as `main.js`.
3. Save. cmux reloads the sidebar at once.

| File | Shows |
| --- | --- |
| `dots.js` | The quietest list: a blue unread dot, the title, and a spinner while an agent works |
| `board.js` | Workspaces grouped by "Needs you", "Working" and "Idle" |
| `cards.js` | One card per workspace, with its agents and a colored edge for their state |

The scripts are classic cmux sidebars (`sidebar(fn)`, `data.workspaces()`, `cmux(method, params)`).
See `docs/cmux-next/sidebar-customization.md` and `plans/cmux-next/custom-sidebar-DESIGN.md`.
