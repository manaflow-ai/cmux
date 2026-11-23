# Pane operations

Five opt-in shortcuts for existing cmux NEXT pane actions. Every binding requires
`terminalFocused && !paletteOpen`; this is the native keybinding context, not a
new focus rule. The bindings do not replace Cmd+W, Cmd+C, Cmd+V, or any chord in
the sibling panes, terminal, tabs, and palette packs.

## Install and preview

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/rex/pane-operations@lane/rex-feature-looks
```

Remove this layer with `cmux setup remove manaflow-ai/rex-pane-operations`.
The package owns five keybinding entries and no settings. Native actions remain
available through their existing palette/context-menu routes.

For a standalone draft preview, from the repository root:

```sh
cmux customize use examples/looks/rex/pane-operations/profile.json
cmux customize check
```

Review the draft, then choose `cmux customize apply` or `cmux customize discard`.
The profile contains this pack's five bindings only; use the combined pack's
profile to preview all shortcut packs together. The installable setup loads its
adjacent `keybindings.json`, while the portable preview embeds the same bytes.

## Actions and actual scopes

All shortcuts below start with **Ctrl+Opt+Cmd**. The extra Shift on close-others
keeps that broader action distinct from close-pane. These chords are adaptation
choices, not claims about the source application's defaults.

| Key | Native action ID | What it affects |
| --- | --- | --- |
| Ctrl+Opt+Cmd+W | `closePane` | The focused pane and all tabs it contains. This is broader than closing its active tab. |
| Ctrl+Opt+Cmd+Shift+W | `pane.closeOthers` | Other panes on the focused pane's **screen**, including non-terminal panes and their tabs. Pinned dock panes are excluded. |
| Ctrl+Opt+Cmd+T | `pane.moveToNewWorkspace` | All tabs of the focused pane, in order, into a new workspace. Refused if this is already the workspace's only pane. |
| Ctrl+Opt+Cmd+N | `pane.moveToNewWindow` | The focused pane's tabs into a workspace in a new native window. If it is the workspace's only pane, the existing workspace moves to that window. |
| Ctrl+Opt+Cmd+C | `palette.copyPaneID` | Copies `pane_id=<native pane ID>` to the clipboard. It copies an identifier, not selected terminal text or a working-directory path. |

Terminal focus controls where these keys can start. It does **not** narrow the
native actions to terminal tabs: a pane can also contain browser or agent tabs,
and close/move affects those too. Opening the palette suppresses these bindings;
the native palette commands keep their own availability rules.

Close and move retain native handling of pending creations, pinned panes,
refusals, closed history, and undo. This package adds no confirmation bypass or
process-management code. It does not promise an additional close confirmation.
Moves follow the existing same-machine daemon route, preserving running tabs
rather than spawning replacement terminals; live behavior still needs target-app
verification.

## Source mapping and limits

| Source action/evidence | Mapping |
| --- | --- |
| `pane.close` | `closePane`; close the containing pane, not just its active tab. |
| `pane.close_others` | `pane.closeOthers`; cmux's containing-screen scope is explicit above. |
| `pane.move_to_new_tab` | Adapted to `pane.moveToNewWorkspace`; the two applications' tab/workspace hierarchies differ. |
| Pane/window organization | `pane.moveToNewWindow` is an additional native operation, not an asserted exact source action. |
| `pane.copy_id` | `palette.copyPaneID`; uses cmux's identifier namespace and `pane_id=` output format. |

Moving a whole pane into an arbitrary existing source-style tab is not mapped.
The native `moveSurfaceToNextPane` family moves one tab, which would silently
change the object being moved. Existing copy/paste stays in the terminal pack.
`palette.terminalOpenDirectory` is not used as a path-copy replacement: its
handler opens a local filesystem URL, which does not establish remote-directory
browsing or copying the terminal's current path. `workspace.copyPath` is also not
substituted for a terminal directory.

This package changes no colors, layouts, fonts, toolbar buttons, session
membership rules, or app defaults outside its installed shortcut entries. Its
source-to-native relationships and exact handler locations are in
[EVIDENCE.md](EVIDENCE.md).

## Source screenshot

![Source reference showing pane headers and a close affordance; not a screenshot of this pack running](references/source-window.webp)

The supplied public window image establishes the pane organization being mapped.
It does not prove shortcut behavior, hidden menus, or a native move operation.
It is retained as reference material, not used as wallpaper or installed UI.
