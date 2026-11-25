# User key modes (row key-modes)

A key mode is a layer of bare keys a person defines in keybindings.json and turns on with a key.
While the mode is on, `h`, `j`, `g g` run that mode's actions instead of typing. Escape ends it.

The TUI does not ship Zellij-style modes (cmux-tui/docs/keyboard.md, the non-goal at line 197) because its
modes would take shell control keys. That choice is the TUI's. In the NEXT Mac app, a mode is
something the person defines and enters on purpose, and it never takes a key in a text field.

## Defining one

```jsonc
[
  // Cmd-K R enters the "pane" mode.
  {"key": "cmd+k r", "command": "keyMode.enter", "args": {"name": "pane"}},
  // In it, bare h/l move focus and x closes the tab.
  {"key": "h", "command": "focusLeft", "when": "keyMode == 'pane'"},
  {"key": "l", "command": "focusRight", "when": "keyMode == 'pane'"},
  {"key": "x", "command": "closeTab", "when": "keyMode == 'pane'"},
  // q leaves the mode (Escape does too, unless the mode binds Escape).
  {"key": "q", "command": "keyMode.exit", "when": "keyMode == 'pane'"}
]
```

From the CLI: `cmux app key-mode-enter --name pane` and `cmux app key-mode-exit`. From the palette:
Enter Key Mode… and Exit Key Mode.

## Rules

- **Context key.** `keyMode` holds the name of the mode that is on, and is absent outside a mode. It is
  app-wide: one mode at a time. Entering another mode ends the first.
- **Which entries may bind a bare key.** An entry with a bare first stroke binds when its `when`
  requires `keyMode == 'name'` or `keyMode` as an `&&` term. Its `when` may also not require a
  text-field key (`textInputFocus`, `terminalFocused`, `browserFocused`...). This is the same
  rule as the bare-key pages (diff viewer, read-only markdown). The daemon's reader
  (cmux-config `keybindings::bare`) and the app's loader (`WhenClause.allowsBareKeys`)
  apply it, and `schemas/keybindings/keybinding-vectors.json` pins both.
- **Which focus the mode takes keys in.** Any focus except a text field: a terminal, a web page
  and the sidebar all qualify. A text field (a native field, or an editable element in a page)
  keeps typing.
- **Keys the mode does not bind.** Escape with no binding of its own ends the mode. Any other bare
  key the mode does not bind is swallowed: a mode is a layer, and Escape gets the page back.
  Chords (Cmd, Ctrl, Opt) route as usual, with `keyMode` in their context.
- **The indicator.** While the mode is on, the which-key overlay names it and lists the bare keys
  it binds in this focus.

## Where it lives

- Rust:
  - cmux-config `keybindings::bare` holds the bare-key rule.
  - cmux-action-catalog `catalog/key_mode.rs` holds `keyMode.enter` (arg `name`) and `keyMode.exit`.
- Swift (the key router and context wiring):
  - `KeyContext.keyMode`, `KeyContext.inKeyMode` and `WhenClause.requiresKeyMode` are in CmuxNextActions.
  - `KeyModeLayer` (CmuxNextFocusUI) holds the mode, the indicator and the `keyMode.enter`/`exit` handlers.
  - The key router's `routesBareKey` gives a mode its keys.

Prior art: Lawrence's draft (#24186, `keyMode.enter.<name>`, context key `keyMode`) and the
sticky keyboard modes (#20368).
