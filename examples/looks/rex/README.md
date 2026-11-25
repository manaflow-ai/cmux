# Rex workspace looks

Install [the whole setup](whole) for the creation page, host list and activity, session search, window proportions, keyboard controls and appearance. Each feature also installs independently.

| Feature | What you can do |
| --- | --- |
| [New Tab](new-tab) | Start a terminal in this workspace, create a local workspace, choose a machine or add a remote host. |
| [Hosts](hosts) | Browse chats by host, start a chat on that host and open host setup. |
| [Activity](activity) | Watch chats that need input, failed, finished unread or are working, by priority or project. |
| [Session picker](session-picker) | Search chats by name, host, project or folder, and filter by activity. |
| [Tabs and windows](tabs) | Open and move tabs, select by number, open and close windows, and toggle full screen. |
| [Session operations](session-operations) | Cycle between workspaces in a group, return to the last workspace, rename or close the selection. |
| [Palette](palette) | Open commands, find tabs, rename the focused tab and revisit the last location. |
| [Panes](panes) | Split, focus, swap, balance and zoom terminal panes with the keyboard. |
| [Pane operations](pane-operations) | Close a pane, close its neighbors on the same screen, move its tabs to a fresh workspace or window, or copy its native ID. |
| [Terminal](terminal) | Adjust type size, copy and paste, find, scroll and enter copy mode. |
| [Toolbar](toolbar) | Use compact top tabs and native split and zoom buttons with inset pane borders. |
| [Appearance](appearance) | Switch between three measured terminal palettes with matching sidebar groups and chat links. |
| [Preferences](preferences) | Use background banners, tab activity indicators, a Dock badge, larger sidebar text and 13-point terminal type. |

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/rex/whole@feat-cmux-next
```

From the repository root, preview any feature with `cmux customize use examples/looks/rex/FEATURE/profile.json`. Run `cmux customize check`, then `cmux customize apply` to keep it or `cmux customize discard` to restore the previous configuration. Hosts, Activity, Session picker and New Tab each supply their own customize app. The whole setup combines those views.

[Source workspace image](https://www.superlogical.com/rex-screenshot@2x.webp) · [Measurements and coverage](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/docs/research/competitor-maps/rex.md)
