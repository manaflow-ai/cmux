# Windows and Workspaces

```bash
# inspect
cmux window list
cmux workspace list --json
cmux workspace current show --json

# lifecycle
cmux app new-window                       # app action
cmux workspace create --name api
cmux workspace ws_… focus
cmux workspace ws_… rename --name infra
cmux workspace ws_… close

# order and move
cmux workspace ws_… move --index 0
cmux workspace move-to-window --target ws_… --window <window-id>   # app action
```

Windows exist only in the app; their ids are the lowercase UUIDs `cmux window list` prints.

## Context-menu actions

Workspace right-click actions are app actions. List them with `cmux action list --noun workspace` and check arguments with `cmux action describe "workspace set-color"`.

```bash
cmux workspace set-color --target ws_… --color blue
cmux workspace edit-description --target ws_… --description "Ship checklist"
cmux workspace pin-unpin --target ws_…
cmux workspace clear-name --target ws_…
cmux workspace set-status --target ws_… --status working
```

Colors: grey, blue, red, yellow, green, pink, purple, cyan, orange. Statuses: auto, todo, working, needs-attention, review, done (`mark-as-done` and `cycle-status` set done or the next one). Other actions include `mark-as-read`, `mark-as-unread`, `move-up`, `move-down`, `move-to-top`, `close-other`, `close-above`, `close-below`, `close-all` (every workspace in a window) and `close-all-in-all-windows`; `cmux app close-other-windows` and `close-all-windows` close windows (terminals keep running); `cmux workspace-group close-others` and `duplicate`; `cmux sidebar close-section-workspaces` and `new-section-workspace` (Pinned too); `cmux agent archive-chat --target pane:…`. A script passes `--confirm` to the close verbs that close several workspaces.

## Groups

```bash
cmux workspace group list
cmux workspace group create --name backend --color blue
cmux workspace group backend add --workspace ws_…
cmux workspace group remove --workspace ws_…
cmux workspace placement list --json      # personal sidebar order
```

Groups and rooms take their id or exact name. Both are personal: they live in this Mac's home session.

## Every sidebar action from the CLI

Each thing a person does to a workspace or group in the sidebar has a verb. Order verbs change the personal order the sidebar shows (`cmux workspace list --order personal`), the same way a drag does.

| In the sidebar | CLI |
| --- | --- |
| Drag a workspace above or below another row (into its group, or out of a group) | `cmux workspace move-above --target ws_… --anchor ws_…`, `move-below` |
| Move a workspace to the top or bottom of its group or the loose rows | `cmux workspace move-to-top --target ws_…`, `move-to-bottom` |
| Move a workspace one row up or down | `cmux workspace move-up --target ws_…`, `move-down` |
| Pin or unpin a workspace | `cmux workspace pin-unpin --target ws_… [--pinned true\|false]` (without `--pinned` it toggles) |
| Add to or remove from Top | `cmux workspace toggle-top --target ws_…` |
| New group, or a group from workspaces | `cmux workspace-group create --target ws_… [--name …]`, `cmux workspace move-to-new-group --target ws_…` |
| Move a workspace into or out of a group | `cmux workspace-group add-workspace --target ws_… --group <group>`, `remove-workspace --target ws_…` |
| Rename, recolor, set the icon of a group | `cmux workspace-group rename --target <group> --name …`, `set-color`, `set-icon` |
| Collapse or expand a group (or all) | `cmux workspace-group collapse --target <group>`, `expand`, `collapse-all`, `expand-all` |
| Pin or unpin a group | `cmux workspace-group toggle-pin --target <group> [--pinned true\|false]` |
| Reorder groups | `cmux workspace-group move-up --target <group>`, `move-down`, `move-to-top`, `move-to-bottom` |
| Ungroup or delete a group | `cmux workspace-group ungroup --target <group>`, `delete --target <group> --confirm` |

`move-above` and `move-below` move within one sidebar section of one window; to pin, use `pin-unpin`.

## Rooms

```bash
cmux room list --json
cmux room create --name Work --color blue
cmux room Work pin --workspace ws_…
cmux room unpin --workspace ws_…
cmux room Work follow --sessions s1,s2      # the complete follow set
cmux room Work update --icon briefcase --clear-color
cmux room Work move --index 0
cmux room Work delete --move-to Home
```

## Workspace metadata and closed history

```bash
cmux workspace ws_… update --title "API" --color "#336699" --icon server.rack
cmux closed list
cmux closed <closed_id> reopen
```
