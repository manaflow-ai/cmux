# Tab and window navigation

An opt-in layer with **20 bindings, 11 distinct cmux actions, zero settings**.
Three window keys apply outside the command palette. The other 17 bindings
require `terminalFocused && !paletteOpen`: browser, chat and text-field focus
keep their own keys. They still work inside terminal full-screen applications,
where the listed Ctrl keys are intentionally claimed by this profile.

## Mapping

| Source action | cmux action | Keys |
| --- | --- | --- |
| `client.window.new` | `newWindow` | Cmd+N |
| `client.window.close` | `closeWindow` | Cmd+Shift+W |
| `client.window.fullscreen.toggle` | `toggleFullScreen` | Ctrl+Cmd+F |
| `client.tab.new` | `newSurface` | Cmd+T |
| `client.tab.close` | `closeTab` | Opt+Cmd+W |
| `client.tab.next` | `nextSurface` | Ctrl+Tab, Shift+Cmd+] |
| `client.tab.previous` | `prevSurface` | Ctrl+Shift+Tab, Shift+Cmd+[ |
| `client.tab.move.backward` | `moveSurfaceLeft` | Ctrl+Shift+PageUp |
| `client.tab.move.forward` | `moveSurfaceRight` | Ctrl+Shift+PageDown |
| `client.tab.goto` | `selectSurfaceByNumber` with explicit `index: 1…8` | Cmd+1…8 |
| `client.tab.recent.in_session` | `focusTabRecentInWorkspace` | Cmd+' |
| `client.tab.recent` | `focusTabRecent` | none (palette; bind your own) |
| `client.tab.back` | `focusTabBack` | none (palette; bind your own) |
| `client.tab.back.in_session` | `focusTabBackInWorkspace` | none (palette; bind your own) |

## Semantic limits

- Tabs here are cmux tabs in the focused pane. New Tab opens a terminal;
  this does not reproduce another application's session hierarchy or tab creation picker.
- Numbering follows the visible tab strip, excluding collapsed group members.
  **Cmd+9 is deliberately absent**: cmux index 9 means last tab, whereas the
  source documents numbered selection through 9. Missing indices do nothing.
- `client.close` has pane → tab → window fallback semantics. No matching
  composite action is installed. Cmd+W keeps cmux's existing behavior;
  Opt+Cmd+W explicitly closes the focused tab, not its entire split layout.
- Tab history is its own model, not the location trail: every tab you
  settle on is a visit, whatever `navigation.history.scope` says, and the
  `InWorkspace` actions are strict (only tabs of the current workspace on
  the same machine, never a page or another workspace). A session here is a
  cmux workspace. Back walks one tab further per repeat; Recent toggles
  between the last two. Like the source, only the session-local recent
  toggle gets a key (Cmd+'); the other three are listed with no key, so
  bind them yourself. Cmd+' is never global history; the sibling palette
  profile keeps its last-location adaptation on Opt+Cmd+'.
- The four tab-history actions arrive with the app build that carries the
  native tab history change. On an older build the profile still applies
  (`customize check` reports no problems) but Cmd+' does nothing.
- Close Other Tabs is pane-local in cmux. Move to New Workspace is not Move
  to New Window. Audio mute is not notification mute. Those source actions
  are omitted rather than relabeled as equivalent.
- Opt+Cmd+W can supersede a different existing binding in terminal focus;
  Cmd+N and Cmd+Shift+W override existing window/workspace shortcuts outside
  the palette. Review them before applying.

## Install and undo

From a checkout, preview this profile (it writes no settings until you run it):

```sh
cmux customize use examples/looks/rex/tabs/profile.json
cmux customize check
```

Keep it with `cmux customize apply`, or undo the preview with
`cmux customize discard`. The shortcut layer merges by key and context; review
existing custom bindings before applying. A later file binding wins a collision.

Once this branch is published, the standalone setup is installable with:

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/rex/tabs@feat-cmux-next
cmux setup remove manaflow-ai/rex-tabs
```

Only use the remove command to uninstall. No defaults are changed in the app.
`profile.json` embeds the exact `keybindings.json`; `cmux-setup.json` discovers
that sibling file. There are zero settings and zero custom executable actions.

## Source reference

[Official action reference](https://www.superlogical.com/rex/docs/reference/mac-actions),
[official shortcuts](https://www.superlogical.com/rex/docs/customize/keyboard-shortcuts),
and [official installation page](https://www.superlogical.com/rex/docs/installation).
The source window capture is linked from the neighboring launcher example:
[source screenshot](../new-tab/screenshots/source-window.webp), attributed to
[the official product site](https://www.superlogical.com/rex).
This is a source reference, not a capture of these shortcuts running in cmux.
