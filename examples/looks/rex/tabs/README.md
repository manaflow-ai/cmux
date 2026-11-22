# Tab and window navigation

An opt-in layer with **19 bindings, 10 distinct cmux actions, zero settings**.
Three window keys apply outside the command palette. The other 16 bindings
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

## Semantic limits

- Tabs here are cmux tabs in the focused pane. New Tab opens a terminal;
  this does not reproduce another application's session hierarchy or tab creation picker.
- Numbering follows the visible tab strip, excluding collapsed group members.
  **Cmd+9 is deliberately absent**: cmux index 9 means last tab, whereas the
  source documents numbered selection through 9. Missing indices do nothing.
- `client.close` has pane → tab → window fallback semantics. No matching
  composite action is installed. Cmd+W keeps cmux's existing behavior;
  Opt+Cmd+W explicitly closes the focused tab, not its entire split layout.
- Cross-session tab history, session-local tab history and session-local
  recent-tab toggling have no exact mapping here. In particular Cmd+' is
  not assigned to global history. The sibling palette profile offers an
  explicitly named last-location adaptation on a different key.
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
cmux setup install github.com/manaflow-ai/cmux/examples/looks/rex/tabs@lane/rex-feature-looks
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
