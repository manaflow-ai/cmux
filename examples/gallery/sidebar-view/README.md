# Starter Sidebar View

A view of your own: a customize app built with the Scene SDK. It draws the sidebar's hover card
and decorates its rows. It uses the SDK's view kit and names no color, so it follows any theme.

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Turns hover cards on with a 300 ms delay |
| `customize/cmux-app.json` | The app manifest for `local/customize`. It implements `cmux.hovercard/1` (`renderCard`) and `cmux.sidebar.rows/1` (`decorateRows`) and asks for `workspace:read` |
| `customize/main.js` | `renderCard` draws three lines: the title and age, the agent's status, and the branch. `decorateRows` puts a dot on each workspace row while an agent works, using `cmux.live("workspace.list")` |

While it is installed, it stands in for your own `customize/` view if you have one.
`cmux setup remove` puts yours back. The interfaces are described in
[sidebar-customization.md](../../../docs/cmux-next/sidebar-customization.md).

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/gallery/sidebar-view@feat-cmux-next
cmux setup remove manaflow-ai/starter-sidebar-view
```
