# Workspace tabs

Workspaces work the way a browser's tabs do.

| Setting | Does |
| --- | --- |
| `sidebar.workspacesAsTabs` | Each workspace is one line; Shift-Command-[ and ] step through them |
| `sidebar.chromeGroups` | Workspace groups get a colored rail with a rounded end, like a browser's tab groups |
| `sidebar.sideBySide` | Drag a workspace row onto a pane's edge to show it beside the one you are in |
| `tabs.commandDigits: workspaces` | Command-1 to 9 picks a workspace (Control-1 to 9 a tab) |
| `tabs.hideLoneChatTab` | A chat alone in its pane has no tab of its own |
| `tabs.newTabPosition: afterCurrent` | A new tab opens next to the one you are in |
| `tabs.overflow: scroll` | Many tabs scroll and keep their width instead of shrinking |
| `sidebar.density: compact` | Shorter sidebar rows |

It changes settings only; `remove` puts each one back as it was.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/workspace-tabs@feat-cmux-next
cmux setup remove manaflow-ai/workspace-tabs
```

Or try it as a preview: `cmux customize recipes --open`, then the Workspace tabs recipe's Run button.
