# Rex whole setup

Open New Tab to start a terminal or workspace and search existing chats. The Hosts sidebar groups those same chats by machine. This setup also installs pane chrome, tab and terminal shortcuts, notification and text preferences, and three color palettes. Graphite is selected initially.

## Preview, install and undo

From the repository root, preview the complete setup with the installed cmux CLI.

```sh
cmux customize use examples/looks/rex/whole/profile.json
cmux customize check
```

Run `cmux customize apply` to keep the preview or `cmux customize discard` to return to the preceding configuration. To install the repository version as a removable layer, use a build with setup subpath support.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/rex/whole@feat-cmux-next
cmux setup remove manaflow-ai/rex-whole
```

The second command removes the layer. Enable **Run actions** for the local customize app in Settings → Apps to use its buttons. The combined view occupies the same local app slot as the individual view packs. Choose the whole setup to use all three views together.

## Working in the setup

| Surface | What you can do |
| --- | --- |
| New Tab | Use the tab-strip **+** to open the combined page. With a terminal focused and the palette closed, **Cmd+T** runs **New Tab in Session** directly and opens a terminal in the current pane. **New Local Session** creates a workspace on the local machine. **New Session on Host…** opens the native palette filtered to **New Workspace on Machine**, where cmux resolves the destination. **Add Remote Host…** opens the connection flow. |
| Sessions on New Tab | Search across chats by title, ID, machine, folder, project or harness. Return opens the first match. **Show activity** narrows the list to active or unread chats. **New local chat** starts an agent chat. |
| Hosts sidebar | Choose This Mac or a peer to see its chats and start a chat on that host. Host selection and search stay local to the section. Both views share chat updates and preserve the host when opening a remote session. |
| Activity mode | **Show activity** switches the Hosts section to chats grouped by priority (needs input, failed or lost, unread, working) or by project, with **Include idle** for the rest; **Show hosts** switches back. The mode persists. [Activity](../activity) |
| Toolbar and panes | Split right, split down or zoom from the top tab bar. Terminal-focused shortcuts add directional splits, focus, swaps, floating and equalization. [Toolbar](../toolbar) · [Panes](../panes) |
| Tabs, palette and terminal | Use Cmd+1 through Cmd+8 to select numbered tabs with terminal focus and the palette closed. Cmd+Shift+P opens the command palette. Each pack lists its exact chords, focus conditions and arguments. [Tabs](../tabs) · [Palette](../palette) · [Terminal](../terminal) |
| Workspace operations | From a terminal with the palette closed, press **Ctrl+Option+Cmd+J**, then **N/P** to cycle grouped workspaces, **L** for the last used workspace, **R** to rename, or **W** to close. Close follows the native workspace selection and confirmation settings. [Session operations](../session-operations) |
| Pane operations | With the same focus conditions, **Ctrl+Option+Cmd+W** closes the pane and its tabs. Adding **Shift** closes other eligible panes on the screen. **Ctrl+Option+Cmd+T/N** moves the pane's tabs to a new workspace/window, and **Ctrl+Option+Cmd+C** copies its pane ID. [Pane operations](../pane-operations) |
| Appearance and preferences | Switch palettes with `cmux theme use rex-paper`, `rex-tide` or `rex-graphite`. The setup enables background banners, Dock badges and activity cues, and sets larger sidebar rows and 13-point terminal text. [Appearance](../appearance) · [Preferences](../preferences) |

## Reference screenshots

The source window in light and dark shows the pane layout and tab strip used as references. The whole setup keeps your existing workspace layout. The screenshots depict the source application.

![Light reference window with a top tab strip and three terminal panes](../new-tab/screenshots/source-window.webp)

![Dark reference window with terminal panes and top tab strip](https://www.superlogical.com/rex-screenshot-dark@2x.webp)

## Scope

- The Sessions list contains agent chats. Host groups come from visible chats, plus This Mac. Remote machines with no chats can still be selected in the native workspace picker. Working, needs input, failed, lost and unread describe agent state. [Hosts](../hosts) · [Session picker](../session-picker)
- The setup selects the local customize New Tab page, including when the native page was previously enabled. The creation rows appear on that page. The native plus popover, its placement and menu ordering are separate surfaces. [New Tab](../new-tab)
- Pane corners and gaps are cmux settings. Each pane has its own tab strip. Terminal copy mode uses cmux’s own navigation. Full terminal-format themes, shell configuration, SSH credentials and host-management settings have separate owners. [Appearance](../appearance) · [Terminal](../terminal)
- Chat search and the host filter fit the SDK's list viewport. Opening a connection or session still uses the native readiness checks and action permissions.

## Maintaining the combined pack

Run `python3 examples/looks/rex/whole/compose.py` after changing a component, or add `--check` to detect drift. The setup manifest uses adjacent files. The preview profile embeds the same files so an installed binary can load the JSON on its own. The combined app owns both view exports. Its New Tab content and Hosts section are maintained together in `customize/main.js`.

The composer rejects conflicting settings, payloads and shortcuts. It compares shortcut strokes, focus conditions, command IDs and arguments. To exercise both exports, independent searches, native action requests and mount lifetimes against the repository's app runtime, run `node examples/looks/rex/whole/verify-views.mjs` with Node 24.
