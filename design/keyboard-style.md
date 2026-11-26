# Settings > Keyboard: Key Style and Keyboard Layout

Leo, 2026-11-16: "hey whilewe're at it shouldnt we have that kinda access available for key...
stuff? idk, vim or not, dvorak...?"

Two app-wide settings, first card on Settings > Keyboard (`settings.group.keyStyle`), above
Shortcut Hints:

| Key | Choices | Default |
| --- | --- | --- |
| `app.keyStyle` | Standard, Vim, Emacs | Standard (today's keys) |
| `app.shortcutLayout` | Follow My Layout, Keep QWERTY Positions | Follow My Layout (today: Cmd-Z is the key that types Z) |

Both are standard choice rows (`schemas/settings/source/keyboard-style.json`), so the Settings
page draws its picker, the palette gets "Key Style" and "Keyboard Layout" rows with the same
choices, and `cmux settings set app.keyStyle vim` and MCP `settings_set` work (agent-settable).

## References

- `zed/web/theme-keymap-agent-setup`: Zed asks for Base Keymap and Vim Mode on its first page,
  next to the theme. A keymap style is a top-level preference, not something buried under
  per-action shortcuts. cmux puts it first on Settings > Keyboard, as one picker row instead of
  a grid of logos (Settings card look, `design/settings-keys.md` Tokens).
- `cursor/live/keyboard-shortcuts-overlay`: shortcuts are listed by what they do; the layout
  choice must not change those labels' meaning, only which key fires them.

## One keymap layer

`schemas/keymap/key-styles.json` is the one table: each style's strokes to list commands
(`list.next`, `list.previous`, `list.first`, `list.last`, `list.pageDown`, `list.pageUp`,
`list.open`, `list.back`, `list.search`, `list.leave`), and every physical key's US character
and macOS key code. Two readers, one behavior:

- `cmux-tui/crates/cmux-keymap` (Rust), linked into the app through CCmuxAppFFI
  (`include/cmux_keymap.h`): the native surfaces (sidebar, command palette, native New Tab) and
  the shortcut matcher (`ActionRegistry.shortcuts(for:)`).
- `webviews/src/ui/keyStyle.ts` and `useListKeys`: the web surfaces (chat list, Settings lists,
  New Tab page, pickers).

Both run every case of `schemas/keymap/key-vectors.json`: synthetic key events on QWERTY,
Dvorak, Colemak, AZERTY and QWERTZ, for every style and both layout modes.

Until the app FFI pin carries cmux-keymap (the release is built from feat-cmux-next after this
lands), the native shortcut matcher reads Keep QWERTY Positions from a Swift copy of the US key
table (`CmuxNextActions/ShortcutKeyPositions.swift`, `ActionRegistry.matchesQwertyPositions`):
Command and Control shortcuts go by key position, in the dispatcher, chords, the leader layer, the
recorders and global hot keys. The re-pin replaces it with `cmux_keymap_candidates`.

## Code Editor

`editor.vimMode` (Settings > Code Editor, "Vim Keys in the Editor", off by default) turns on
monaco-vim in the code editor: Normal, Insert and Visual modes, the mode and the `:` prompt in the
status bar, loaded only when on (`webviews/src/pages/editor/vimMode.ts`). It is its own switch:
Key Style Vim moves lists and leaves text fields typing as usual, and modal editing is a separate
choice, as in Zed and VS Code.

## Key Style

- **Standard**: nothing added.
- **Vim**: in any list with the keyboard, j and k move, h goes back and l opens, gg and G go to
  the first and last row, Ctrl-D and Ctrl-U page, / focuses the list's search field, and Esc
  leaves it (a search field gives the keyboard back to its list; a list closes or returns focus,
  as Esc does today). Vim also turns on `browser.vimKeys` (page keys f, F, j, k, gg, G); the
  terminal keeps Ghostty's own keys and cmux copy mode, which already moves with hjkl, so
  nothing is added to the Ghostty config.
- **Emacs**: Ctrl-N and Ctrl-P move in lists and also while a list's search field has the
  keyboard (the palette); Ctrl-F opens, Ctrl-B goes back, Ctrl-A and Ctrl-E go to the first and
  last row, Ctrl-V and Alt-V page, Ctrl-S searches, Ctrl-G leaves. In text fields Ctrl-A, E, F
  and B keep moving the caret, as macOS text fields already do.
- Text fields keep normal typing: a stroke without Control, Option or Command never reaches the
  list layer while a text field has the keyboard, except Esc in Vim.
- A key the layer does not take goes on to the surface unchanged (arrows, Return, Cmd keys).

## Keyboard Layout

- **Follow My Layout** (default): a shortcut is the character the layout types. Three fallbacks
  keep every shortcut reachable on any layout: a digit-row key is also its digit (AZERTY's &
  key is Cmd-1), a key that types a non-ASCII character or is a dead key is also its US
  position (QWERTZ's ü key is Cmd-[), and a character the layout types only with Shift matches
  a shortcut without Shift (AZERTY's / is Shift-:), but never a letter's capital.
- **Keep QWERTY Positions**: a shortcut is the physical US key position, whatever the layout
  types: on Dvorak, Cmd-Z is the key labeled ; and Cmd-/ is the key labeled Z. Key Style keys
  follow the same choice.

## States

| State | What shows |
| --- | --- |
| Default | Key Style: Standard; Keyboard Layout: Follow My Layout. Nothing changes from today. |
| Vim | j/k move the highlighted row in the sidebar, palette results, chat list, Settings lists and New Tab. |
| Emacs | Ctrl-N/P move the same rows, also while typing in the palette. |
| QWERTY positions on Dvorak | Cmd-Z, Cmd-/ and Vim's j/k sit on the US keys. |
| Input source changes | The next key uses the new layout; nothing to reload. |

## Presets

The keymap file Settings > Keyboard Shortcuts already exports and imports
(`cmux.keybindings.keymap.export|import`, `SettingsController+Keymap.swift`) carries `shortcuts`.
It gains `app.keyStyle` and `app.shortcutLayout`, so one file shares a whole keyboard setup.

## Copy

Title Case for the card, rows and choices (Settings convention); one short help line per row.
Strings in `CmuxNextSettings/Localizable.xcstrings` (`settings.app.keyStyle*`,
`settings.app.shortcutLayout*`, `settings.choice.keyStyle*`, `settings.choice.shortcutLayout*`,
`settings.group.keyStyle`).
