# Instrument

Instrument v0.1 is a dense, quiet frame for cmux. Every corner, gap and tone is computed from three
numbers. There is no accent colour: selection, focus and links are drawn in the text colour, and
colour is kept for status (red, green, yellow). It leaves your glass, wallpaper and motion settings
alone.

## The numbers

Seeds: a 4 px grid, a 28 px row and 13 px chrome text.

Corners follow one rule: a box's corner is the control corner plus its inset, and never more than a
third of its height (rounded down to the grid).

| Role | Corner |
| --- | --- |
| Control (button, field, menu row, address field) | 8 |
| Container (pane, card, menu, prompt) | 12 |
| Composer | 16 |
| Dialog | 20 |

Every fill is the theme's ink mixed into its surface at a multiple of 4%:

| Tone | Share | Light | Dark |
| --- | --- | --- | --- |
| Surface | 0% | `#ffffff` | `#1a1a1a` |
| Frame (sidebar, tab bar, browser chrome, docks) | 4% | `#f6f6f6` | `#232323` |
| Hover | 8% | `#ededed` | `#2b2b2b` |
| Selected, hairline | 12% | `#e4e4e4` | `#343434` |
| Control outline, pressed | 16% | `#dadada` | `#3c3c3c` |
| Dim text | 68% | `#636363` | `#acacac` |
| Muted text | 84% | `#3f3f3f` | `#cecece` |
| Ink | 100% | `#1a1a1a` | `#f0f0f0` |

Status: light red `#c0392b`, green `#2e7d32`, yellow `#a15c00`; dark `#ff6b6b`, `#8ad48a`, `#f0c674`.

Chat: 14 px text on 20 px lines, code at 12 px, a 600 px column (80 code characters plus two 12 px
card insets).

## Files

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks the theme file; sets the chat and Markdown type, the column width, theme-coloured diffs, a compact grayscale sidebar with dots, an 8 px address field and a 2 px focus ring. |
| `themes/instrument.json`, `themes/instrument-light.json` | The colour ladder, a terminal palette with neutral grays and the status hues, the chrome metrics (36 px title and tab bars, 256 px sidebar, 28 px rows, 13 px chrome text) and the 12 px pane corner. |
| `agent-pane/theme.css` | The chat's muted and dim text, card fill and line, prompt fill and corner, all mixed from the theme's own colours. Menu tokens are included and take effect once menus read them. |

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/instrument@lane/design-instrument
cmux settings set appearance.themeFile instrument-light    # the light twin
cmux setup remove manaflow-ai/instrument-look
```

## Cannot set yet

| Part | Why |
| --- | --- |
| A corner per role for popovers, menus, toasts, tooltips, cards, the composer and dialogs | Only the pane corner and the prompt corner can be set. |
| The composer's corner, rim and shadow | The composer has no paint tokens yet. |
| Elevation and shadow | No shadow setting exists for any surface. |
| The floating material's tint | Menus and popovers take the system material; its tint cannot be set. |
| The type scale and its line heights | Tool-row text size, chrome weights and the chrome font are fixed; only sizes of the chat, Markdown and chrome text can be set. |
| Menu metrics | Menu highlight inset and corner, icon size and gap are fixed (the menu tokens here are not read yet). |
| Sidebar row inset and icon gap | No setting reaches them. |
| How much of a fill hover and selection take | Hover and selected fills are computed by the app; a look sets only the selection colour. |
| Tab shape | Only the corner join to the pane can be chosen, not the tab's shape. |
