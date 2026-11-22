# Cell

cmux on the terminal's character cell. The chat, the Markdown viewer and code are set in the
terminal's own monospace face at one size, 13 px on a 20 px line, so a reply, a tool call, a diff
and a shell line share one rhythm and line up across panes. Nothing changes size to say what it is:
a thought, a tool call and a result differ by ink level and weight. The terminal theme is the whole
color system: sixteen colors, a background and a foreground, and every surface is derived from
those. No glass, no shadow, no wallpaper; lines are one pixel; corners are 4 px and under.

This is the drop-in look for the design proposal "Cell v0.1" (cmuxterm-hq RFD 0032). It changes no
default.

| Theme file | Page | Sidebar and bars | Lines | Ink | Accent |
| --- | --- | --- | --- | --- | --- |
| `cell` (default, dark) | `#15171B` | `#1D1F23` (page 4% toward ink) | `#32353A` (14%) | `#D7DBE2` (12.9:1) | terminal blue `#7AA8F2` |
| `cell-light` | `#FAFAF8` | `#F1F1EF` | `#DADBDA` | `#1B1E23` (16.0:1) | terminal blue `#1D5CC0` |

Colors 1 to 6 and 8 to 14 of both palettes hold 4.5:1 or more over the page, so any of them can be
text.

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks the theme file. Sets the chat and the Markdown viewer in the monospace face at 13 px on a 20 px line with code at the same size, a 752 px column (96 cells), no minimap. Diffs and sidebar group colors come from the terminal palette. Compact sidebar rows under plain section headings with a count, a dot for status, each chat's age at the right. A one-pixel focus ring. A flat 2 px address field. |
| `themes/*.json` | The sixteen terminal colors, background, foreground and the three derived surfaces. A 40 pt title bar and tab strip (two cells), a 240 pt sidebar with 30 pt rows, 13 pt chrome text, one-pixel dividers and no gutter. A 4 px pane corner with the selected tab joined flush, a one-pixel pane border, no glass, the fast animation speed. |
| `agent-pane/theme.css` | Only `cmux.agentPane.style/1` tokens: three ink levels (100%, 72%, 64%, each a solid mix that holds 4.5:1), tool cards as a one-pixel outline on a 2% fill, your prompt as a faint band with a 2 px corner, links in the terminal blue. |
| `markdown/theme.css` | Headings over a one-pixel rule, code on a faint fill with a 2 px corner, tables and quotes in one-pixel lines, no popover shadow. |

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/cell@feat-cmux-next
cmux settings set appearance.themeFile cell-light
cmux setup remove manaflow-ai/cell-look
```

To put your own terminal theme under it, copy a theme file, replace `colors` and the `ghostty`
lines, and set the sidebar surfaces to your background mixed 4% toward your foreground and the
divider to 14%.

## Not yet possible

| Part | Why |
| --- | --- |
| The window chrome in the monospace face | No setting picks the chrome's font family; `appearance.metrics.chromeFontSize` sets only its size. Sidebar rows, tabs, menus and Settings stay in the system font. |
| Tool rows at the chat's size | Tool rows draw at the app's 12 and 11 px label sizes whatever `agentPane.display.font.size` is. |
| The column in cells | `agentPane.display.width` is in pixels, so 96 cells is right for SF Mono at 13 px only. |
| Surfaces derived from the terminal theme at run time | A theme file states the sidebar and line colors as literals; no key says "background 4% toward foreground". |
| A square tab, a flat composer, flat menus and toasts | No setting reaches the tab's shape, the composer's corner, rim and shadow, or the material of native menus and toasts. |
| The archive, and telling a workspace from a chat | Both are behavior, not paint: a look cannot add a row state, a section or a key. |
