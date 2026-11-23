# Instrument

Look version 0.2.0. It draws the Instrument v0.1 design system (the cmux design system chosen on
2026-11-22) as far as a look can set it today. It is an example: installing it changes no default,
and removing it brings back everything you had.

Instrument is a dense, quiet frame for cmux. Every corner, gap and tone is computed from three
numbers. There is no accent colour: selection is a neutral fill, focus and links are drawn in the
text colour, and colour is kept for status (red, green, yellow). It leaves your glass, wallpaper
and motion settings alone.

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
| Frame (sidebar, tab bar, browser chrome, docks) | 4% | `#f5f5f5` | `#232323` |
| Hover | 8% | `#ececec` | `#2b2b2b` |
| Selected, hairline | 12% | `#e2e2e2` | `#343434` |
| Control outline, pressed | 16% | `#d8d8d8` | `#3c3c3c` |
| Dim text | 68% | `#5a5a5a` | `#acacac` |
| Muted text | 84% | `#343434` | `#cecece` |
| Ink | 100% | `#0d0d0d` | `#f0f0f0` |

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
cmux setup install github.com/manaflow-ai/cmux/examples/looks/instrument@feat-cmux-next
cmux settings set appearance.themeFile instrument-light    # the light twin
cmux setup remove manaflow-ai/instrument-look
```

## Measured on its capture

`screenshots/light.png` and `screenshots/dark.png` are the golden screen (`bun run golden:looks
--looks instrument --setup examples/looks/instrument`, 1280 px wide). Numbers are WCAG contrast
ratios read from those two files.

| What | Light | Dark | Target |
| --- | --- | --- | --- |
| Selected sidebar row against the sidebar | 1.13:1 | 1.24:1 | 1.18 to 1.26 |
| Tool-row text on the card fill | 4.66:1 | 5.66:1 | 4.5 or better |
| Body text on the page | 19.44:1 | 15.27:1 | 4.5 or better |

The light selected row is under its target, and a look cannot fix that: see the first row below.

## What it does not set

It sets no accent colour, no glass, no wallpaper, no motion, no font family, no terminal font, no
shortcuts, and it adds no view. The parts below belong to the system but no look can reach them yet,
so this look leaves them as the app draws them.

| Part | Why |
| --- | --- |
| How strong the selected and hover fills are | The app mixes them from the text colour at fixed shares (selected 6% light, 8% dark). The system asks for 12%. A look sets the colours, not the share, so the selected row reads 1.13:1 in light and 1.24:1 in dark. |
| The selected tab and row in the pane's own tone, and two tones by default | Two tones are a setting of yours (`appearance.twoTone`); this look does not turn it on. |
| The tool-row text tone | Tool rows and "Worked for" take a fixed 58% mix of the text, not the muted token. This look reaches them only through the text colour: the light ink is `#0d0d0d` so that 58% of it holds 4.66:1 on a card. |
| A corner per role for popovers, menus, toasts, tooltips, cards, the composer and dialogs | Only the pane corner and the prompt corner can be set. |
| The composer's corner, rim and shadow | The composer has no paint tokens yet. |
| Elevation and shadow | No shadow setting exists for any surface. |
| The floating material's tint | Menus and popovers take the system material; its tint cannot be set. |
| The type scale and its line heights | Tool-row text size, chrome weights and the chrome font are fixed; only the sizes of the chat, Markdown and chrome text can be set. |
| Menu metrics | Menu highlight inset and corner, icon size and gap are fixed (the menu tokens in `agent-pane/theme.css` are not read yet). |
| Sidebar row inset and icon gap | No setting reaches them. |
| The sidebar group heading and the tab strip's + | Fixed mixes in the window chrome: the heading reads 3.43:1 light and 3.77:1 dark, the + 3.74:1 and 4.17:1, under the 4.5 floor. |
| Composer chip detail and the keycap separator | A fixed 45% of the current colour: 2.90:1 and 3.01:1 light, 3.77:1 and 2.81:1 dark. |
| Status hues in the chat | The waiting pill and diff counts keep the app's own yellow, red and green, not the theme's palette: the light waiting pill reads 2.60:1 and the light added-line count 4.35:1. |
| Tab shape and the join to the pane | Only a preset for the corner join can be chosen, not the tab's shape. |
