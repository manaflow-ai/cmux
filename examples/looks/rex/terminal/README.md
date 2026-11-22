# Rex terminal controls

A standalone, opt-in shortcut layer for terminal display size, selection, and
navigation. All bindings use `when: "terminalFocused"`; they do not take browser
zoom, browser find, or text-editor selection keys. No font, color, cursor, shell,
or clipboard preference is chosen on the user's behalf.

## Install or preview

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/rex/terminal@lane/rex-feature-looks
```

To remove the installed layer, run `cmux setup remove manaflow-ai/rex-terminal`.
To preview from the repository root, run the following commands, then choose
`cmux customize apply` or `cmux customize discard`.

```sh
cmux customize use examples/looks/rex/terminal/profile.json
cmux customize check
```

## Mapping

Source: [Mac Actions](https://www.superlogical.com/rex/docs/reference/mac-actions),
Pane, Find, and View sections.

| Source action | cmux action | Installed key |
| --- | --- | --- |
| `client.font.increase` | `terminal.increaseFontSize` | Cmd+=; Cmd+Shift+= |
| `client.font.decrease` | `terminal.decreaseFontSize` | Cmd+- |
| `client.font.reset` | `terminal.resetFontSize` | Cmd+0 |
| `pane.copy` | `terminalCopy` | Cmd+C (cmux convention; source lists no key) |
| `pane.paste` | `terminalPaste` | Cmd+V (cmux convention; source lists no key) |
| `pane.select_all` | `terminal.selectAll` | Cmd+A (cmux convention; source lists no key) |
| `pane.copy_mode.enter` | `toggleTerminalCopyMode` | Cmd+Shift+C |
| `client.find.open` | `find` | Cmd+F |
| `client.find.next` | `findNext` | Cmd+G |
| `client.find.previous` | `findPrevious` | Cmd+Shift+G |
| `client.scroll.page_up` | `terminal.scrollPageUp` | Cmd+PageUp (pack choice; source lists no key) |
| `client.scroll.page_down` | `terminal.scrollPageDown` | Cmd+PageDown (pack choice; source lists no key) |

Font actions adjust the focused terminal's font by one point, or reset that
surface's font size. They are not the workspace-wide font actions. Copy uses
cmux's existing selection behavior; with no selection a key-driven Cmd+C is
forwarded to the terminal program. Copy mode is cmux's **toggle**, not a separate
enter-only action. Its movement, selection, yank, and exit keys stay cmux's own.
The pack does not install the source's entire modal key table.

## Display and selection preferences

The [Terminal settings reference](https://www.superlogical.com/rex/docs/reference/mac-settings#terminal)
documents controls, not a fixed font, size, color palette, or cursor preset.
The shortcut layer leaves these display preferences with their existing owners.

| Source control | cmux owner / limit |
| --- | --- |
| Terminal font, font size | Settings `terminal.fontFamily`, `terminal.fontSize`; pick an installed font and desired size in Settings |
| Font style, line height, character spacing, ligatures, fallback fonts | Ghostty configuration; no corresponding setup settings are emitted |
| Cursor style; copy on selection | Ghostty configuration, not invented `terminal.cursorStyle` or `terminal.copyOnSelect` keys |
| Selection foreground/background | Ghostty theme/configuration; no colors are guessed from a settings list |
| Cursor blink intervals, force style, shaders | No verified matching setup setting in this revision |
| Copy shine and rounded selection corners | No verified matching setup setting in this revision |
| Smooth scrolling and smooth terminal resizing | No verified matching setup setting in this revision |
| Option-key behavior and shell startup command | External terminal configuration; left unchanged |

The setup importer's managed paths do not include `~/.config/ghostty/config`.
It therefore cannot reversibly install those external preferences as part of
this layer. The pack makes no claim to carry them or to reproduce their visual
effects. This avoids writing a preference that the app silently ignores.

Prompt jumps (`client.prompt.previous/next`) are not remapped to page scrolling:
they require shell prompt marks and a matching action. Integrated path insertion,
Quick Look, shader effects, copy animations, and link-security preferences are
outside this pack. Cmd+Shift+G becomes Find Previous only in terminal focus;
this does not add the source's separate Go to Directory picker.

## Implementation evidence

Paths relative to the cmux repository:

- `cmux-tui/crates/cmux-action-catalog/src/catalog/terminal.rs`: copy, paste,
  copy-mode toggle, and find identifiers.
- `cmux-tui/crates/cmux-action-catalog/src/catalog/layout.rs`: terminal font,
  select-all, and page-scroll identifiers.
- `cmux-tui/crates/cmux-window-rules/src/tabs_panes.rs`, `TERMINAL_BINDINGS`:
  focused-surface Ghostty font/scroll operations.
- `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handlers/TerminalHandlers.swift`:
  clipboard, select-all, copy mode, and surface dispatch.
- `schemas/settings/source/terminal.json`: the actual font settings.
- `cmux-tui/crates/cmux-customize/src/tree.rs`: supported managed file paths.
- `cmux-tui/crates/cmux-customize/src/setup.rs` and `library/keys.rs`: setup
  loading and per-binding layering.

![Source window, with three terminal panes below the tab strip](../new-tab/screenshots/source-window.webp)
