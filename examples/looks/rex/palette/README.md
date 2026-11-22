# Palette, picker and input

An opt-in layer with **5 bindings, 5 distinct cmux actions, zero settings**.
The first two keys match the source action reference. The last three are
explicit cmux adaptations, with different keys so no source-only behavior is
silently substituted.

| Source / purpose | cmux action | Key | Scope |
| --- | --- | --- | --- |
| `client.palette.toggle` | `commandPalette` | Shift+Cmd+P | Application |
| `client.settings` | `openSettings` | Cmd+, | Application |
| Choose a tab (adaptation) | `tab.search` | Opt+Cmd+P | Terminal, palette closed |
| Rename the current tab (input adaptation) | `renameTab` | Opt+Cmd+R | Terminal, palette closed |
| Recent location (adaptation) | `focusHistoryLast` | Opt+Cmd+' | Terminal, palette closed |

The last-location action toggles between locations, potentially across panes
and workspaces. It is not the source's session-local recent-tab action. Tab
search is not the source's all-objects Go to Anything. Rename uses cmux's native
rename UI; it is not a generic script-returning input prompt.

Typing, selection, Return and Escape remain the native palette's behavior.
No bare keys or terminal Ctrl+N/Ctrl+P bindings are installed. The three
adaptation bindings require `terminalFocused && !paletteOpen`, so opening a
picker or input relinquishes their terminal scope. Existing keys outside that
scope are preserved. Check for existing Opt+Cmd+P/R/' user bindings before apply.

[Pick contract and native alternative](custom-pick.md) and
[input contract and native alternative](custom-input.md) document the custom UI
source independently from the shortcut map. This profile adds no Lua runtime,
custom palette rendering, shell execution or new application API.

## Install and undo

From a checkout, preview this profile (it writes no settings until you run it):

```sh
cmux customize use examples/looks/rex/palette/profile.json
cmux customize check
```

Keep it with `cmux customize apply`, or undo the preview with
`cmux customize discard`. The shortcut layer merges by key and context; review
existing custom bindings before applying. A later file binding wins a collision.

Once this branch is published, the standalone setup is installable with:

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/rex/palette@lane/rex-feature-looks
cmux setup remove manaflow-ai/rex-palette
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
