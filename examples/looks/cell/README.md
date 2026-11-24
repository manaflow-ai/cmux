# Cell

Version 0.2.0. The terminal preset: a drop-in look, not a proposed default.

cmux on the terminal's character cell. The chat, the Markdown viewer and code are set in the
terminal's own monospace face at one size, 13 px on a 20 px line, so a reply, a tool call, a diff
and a shell line share one rhythm and line up across panes. Nothing changes size to say what it is:
a thought, a tool call and a result differ by ink level and weight. The terminal theme is the whole
color system: sixteen colors, a background and a foreground, and every surface is derived from
those. No glass, no shadow, no wallpaper; lines are one pixel; corners are 4 px and under.

This is the drop-in look for the design proposal "Cell" (cmuxterm-hq RFD 0032). It changes no
default. The design debate of 2026-11-22 chose another proposal's skeleton for the default; Cell
stays as the look for people who want the app to read like their terminal.

## Sizes: the 4 / 28 / 13 seeds

Since 0.2.0 Cell takes its chrome sizes from the design system's three seeds, a 4 px grid, a 28 px
row and 13 px text, in place of its own 10 px half-line.

| Part | 0.1.0 | 0.2.0 |
| --- | --- | --- |
| Title bar and tab strip | 40 | 36 |
| Sidebar row | 30 in the theme file, 24 drawn (compact density) | 28 |
| Chrome text | 13 | 13 |
| Chat line | 13 px on 20 | 13 px on 20 |

The chat's 20 px line is on the 4 px grid. Boxes the transcript draws (tool rows, cards, the
composer) keep the app's own heights: a look cannot set them, so Cell does not claim a grid for them.

## Mono prose is a preset

Replies in the monospace face are this look's choice for terminal people, not a claim about how
most people should read. To keep the palette, the lines and the sizes and read replies in the
system face:

```sh
cmux settings set agentPane.display.font.preset system
```

| Theme file | Page | Sidebar and bars | Lines | Ink | Accent |
| --- | --- | --- | --- | --- | --- |
| `cell` (default, dark) | `#15171B` | `#1D1F23` (page 4% toward ink) | `#303237` (14%) | `#D7DBE2` (12.9:1) | terminal blue `#7AA8F2` |
| `cell-light` | `#FAFAF8` | `#F1F1EF` | `#D7D7D6` | `#0B0D10` (18.6:1) | terminal blue `#1D5CC0` |

Colors 1 to 6 and 8 to 14 of both palettes hold 4.5:1 or more over the page, so any of them can be
text.

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks the theme file. Sets the chat and the Markdown viewer in the monospace face at 13 px on a 20 px line with code at the same size, a 752 px column (96 cells), no minimap. Diffs and sidebar group colors come from the terminal palette. Sidebar rows under plain section headings with a count, a dot for status, each chat's age at the right. A one-pixel focus ring. A flat 2 px address field. |
| `themes/*.json` | The sixteen terminal colors, background, foreground and the three derived surfaces. A 36 pt title bar and tab strip, a 240 pt sidebar with 28 pt rows, 13 pt chrome text, one-pixel dividers and no gutter. A 4 px pane corner with the selected tab joined flush, a one-pixel pane border, no glass, the fast animation speed. |
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

## What Cell does not set

It leaves alone: keys, shortcuts and behavior; the window chrome's font family; the size of card
headers and captions; the corners of cards, the composer, menus and toasts; the selected row's
fill; and every default (removing the look restores what you had).

## What its screenshots measure

Measured on `screenshots/cell-light.png` and `screenshots/cell-dark.png`, which draw the web mock
of the window (the native tab join and corners are not in them).

| What | Light | Dark | Note |
| --- | --- | --- | --- |
| Sidebar tone, page tone | `#f1f1ef`, `#fafaf8` | `#1d1f23`, `#15171b` | A step of 1.08:1 light, 1.09:1 dark; the page is the extreme in both. |
| Sidebar width | 240 px | 240 px | As set. |
| Sidebar row | 28 px | 28 px | The selected row's fill is 28 px tall; 0.1.0 drew 24. |
| Tab strip | 36 px | 36 px | From the pane's top edge (y 7) to the strip's bottom line (y 43). |
| Prose on the page | 18.6:1 | 12.9:1 | Mono, 13 px on a 20 px line. |
| Tool rows | 4.7:1 | 5.1:1 | |
| Selected row's title on its fill | 13.7:1 | 7.3:1 | The fill (`#cfd9e7`, `#354258`) is the app's accent tint, not Cell's. |
| Unselected row's title | 5.4:1 | 6.8:1 | |

Under 4.5:1 in these captures, all drawn by the app in colors a look does not set: the sidebar
section label (3.6:1 light, 4.6:1 dark), the age on the selected row (2.8:1 in both), the
"Waiting for you" pill (2.6:1 light, 6.5:1 dark) and the model's effort label (3.0:1 light,
4.1:1 dark). Cards and the composer draw the app's 8 px corner, not Cell's 4. The sidebar's tone
ends at x 240 and the pane's hairline sits at x 247, a 7 px strip that belongs to the mock window.
Cell claims none of these as its own.

## Not yet possible

| Part | Why |
| --- | --- |
| The window chrome in the monospace face | No setting picks the chrome's font family; `appearance.metrics.chromeFontSize` sets only its size. Sidebar rows, tabs, menus and Settings stay in the system font. |
| Card headers and captions at the chat's size | Tool rows follow `agentPane.display.font.size`; a card's header (a diff's file name) and captions stay at the app's 12 and 11 px label steps. |
| The column in cells | `agentPane.display.width` is in pixels, so 96 cells is right for SF Mono at 13 px only. |
| Surfaces derived from the terminal theme at run time | A theme file states the sidebar and line colors as literals; no key says "background 4% toward foreground". |
| A square tab, a flat composer, flat menus and toasts | No setting reaches the tab's shape, the composer's corner, rim and shadow, or the material of native menus and toasts. Cards and the composer draw the app's 8 px corner, not 4. |
| A neutral selected row | A look cannot set the selected row's fill; it draws the app's accent tint. |
| The archive, and telling a workspace from a chat | Both are behavior, not paint: a look cannot add a row state, a section or a key. |
