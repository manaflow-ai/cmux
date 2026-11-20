# Menus and proportions a look sets: the Claude, Codex and Studio values

Leo, 2026-11-19: "i think y'all also ought to emulate the things for context menu styling and such
maybne in those repos too and the layout and proportions as well" / "whenever it makes sense, ofc".

A look (a theme file, a look pack's setup) sets how menus, popovers and the window's proportions
look. Every key below is a look key: a theme file may set it, `cmux settings set` takes it, and a
save applies it to the running app with no relaunch. Unset, each draws today's app. This page puts
the three packs' values for every key in one place; the keys themselves come from these changes:

| Layer | What it styles | Keys | Added by |
|---|---|---|---|
| Menus a page draws (the chat pane's menus, pickers, popovers) | panel, rows, hover, labels, shortcuts, separators, Delete, submenu offset, subtitles | `--menu-*` CSS tokens in a look's `agent-pane/theme.css` | #46846 ([webviews/src/ui/README.md](../../webviews/src/ui/README.md), "Menu tokens a look sets") |
| Menus the app draws (`GlassMenu`) | the same, natively | `appearance.menu.*`, `appearance.popover.*` | the `lane/menu-look-tokens` branch |
| Layout and proportions | header, sidebar, rows, header buttons, divider, spacing, composer | `appearance.metrics.*` | #46861 ([theme-recipes.md](theme-recipes.md), "Layout and proportions") |
| The sidebar's right-click and more-button menus | the system menu, or a `GlassMenu` the menu keys reach | `sidebar.drawnMenus` (off) | this change |

## Sidebar menus a look can reach

The system menu (`NSMenu`) cannot be restyled, so no menu key reaches the sidebar's menus while they
are system menus. `sidebar.drawnMenus: true` opens the sidebar's right-click menus and a row's more
button as a `GlassMenu`: the same rows, titles, icons, shortcuts, checks, submenus, enabled state,
keyboard (Up, Down, Right, Left, Return, Escape, and each row's shortcut while it is open) and
accessibility roles. A submenu opens beside its row, its top on the row's top.

The workspace and group menus' name-and-swatches header is a row view, which a drawn menu does not
draw. With the setting on, those menus keep their **Rename…** row and **Color** submenu instead, so
nothing is lost. Off (the default), every sidebar menu is the system menu, as today.

## Menus

The web values are #46846's, measured from the design references (`MenuLooks.gallery.tsx`,
`MENU_LOOKS`). The native values are those numbers in the `appearance.menu.*` keys; Claude's are
the `lane/menu-look-tokens` fragment, which follows Leo's screenshot (12 corner, 30 rows) where the
measurement says 9 and 24. A dash keeps today's value. "text N%" is the theme's text color at N%.

| Part | Native key | Web token | Claude | Codex | Studio |
|---|---|---|---|---|---|
| Panel corner | `appearance.menu.cornerRadius` | `--menu-radius` | 9 (Leo: ~12) | 15 | 8 |
| Panel edge | `appearance.menu.borderOpacity` | `--menu-border` | text 10% | text 14% | text 12% |
| Panel shadow | `appearance.menu.shadow` | `--menu-shadow` | `0 8px 24px` black 32% | `0 10px 30px` black 30% | `0 4px 12px` black 25% |
| Panel fill | `appearance.menu.fill` | `--menu-fill` | text 9% over the page (~#2b2b2b dark) | — (frosted glass) | text 3% over the page |
| Inner padding, the hover inset | `appearance.menu.padding` | `--menu-padding` | 4 (Leo: ~10) | 12.5 | 4 |
| Row height | `appearance.menu.rowHeight` | `--menu-row-height` | 24 (Leo: 28-30) | 28.5 | 28 |
| Hover corner | `appearance.menu.highlightRadius` | `--menu-hover-radius` | 8 | 8 | 4 |
| Hover fill | — | `--menu-hover-fill` | text 9% | text 8% | text 8% |
| Shortcut column | `appearance.menu.shortcuts` | `--menu-shortcut-color` | `muted`, text 50% | `muted`, text 40% | `muted`, text 45% |
| Section labels ("Open in") | `appearance.menu.sectionLabel` | `--menu-label-color`, `-weight`, `-size` | `muted`, text 50%, 400 | `muted`, text 45% | `muted`, text 49%, 400, 12 |
| Separators | `appearance.menu.separator` | `--menu-separator`, `-inset` | `subtle`, text 10%, inset 11 | `subtle`, text 12%, inset 16 | `subtle`, text 10%, inset 12 |
| Delete | `appearance.menu.destructiveInk` | `--menu-destructive` | `standard`, #de8481 | — | — |
| Disabled rows | — | `--menu-disabled-opacity` | 0.4 | — | — |
| Submenu | `appearance.menu.submenu` | `--menu-submenu-offset`, `-align-offset` | `flush`, 4 right, -4 up | `flush`, 4 right | `flush`, 4 right |
| A row's second line | `appearance.menu.subtitle` | `--menu-subtitle-color` | `muted`, text 50% | `muted`, text 45% | `muted`, text 39% |
| Usage popover padding | `appearance.popover.padding` | — | 12 | — | — |
| Usage popover header | `appearance.popover.header` | — | `strong` | — | — |
| Usage track | `appearance.popover.progressHeight`, `progressFill` | — | 6, `standard` (the accent) | — | — |
| Sidebar menus drawn | `sidebar.drawnMenus` | — | `true` | `true` | `true` |

Letter shortcuts: the Claude reference shows a bare letter on a menu row's right (P, R, F, A, D).
The menu spec (design/menus.md) says not to draw a bare letter keycap there, so no look adds them;
a row shows the shortcut its action really has. Changing that is Leo's call.

## Proportions

#46861's keys and its measured values (`AALookProportionsGalleryTests.looks`). A dash keeps the
density's value.

| Part | Key | Claude | Codex | Studio |
|---|---|---|---|---|
| Header height | `appearance.metrics.titlebarHeight` | 40 (Leo: ~44) | 46 | 52 |
| Sidebar width | `appearance.metrics.sidebarWidth` | 288 | 306 | 255 |
| Sidebar row | `appearance.metrics.sidebarRowHeight` | 26 | 30 | 28 |
| Two-line row | `appearance.metrics.sidebarRowHeightWithSubtitle` | — | — | 78 |
| Row fill to the sidebar's edge | `appearance.metrics.sidebarRowInset` | 8 | 8 | 8 |
| Row fill to its content | `appearance.metrics.sidebarRowPadding` | 10 | 8 | 10 |
| Gap between rows | `appearance.metrics.sidebarRowGap` | 0.5 | 1 | 2 |
| Header button size | `appearance.metrics.toolbarButtonSize` | 21.5 | 28 | 28 |
| Gap between header buttons | `appearance.metrics.toolbarButtonGap` | 3 | 6 | 4 |
| Header button corner | `appearance.metrics.toolbarButtonCornerRadius` | 5 | 14 | 6 |
| Fill under the button that is on | `appearance.metrics.toolbarButtonActiveFill` | 0.14 | 0.1 | — |
| Hairline under the header | `appearance.metrics.headerDivider` | 1 | 0 | 0 |
| Spacing grid | `appearance.metrics.spacingScale` | — | — | 1.25 |
| Composer side padding | `appearance.metrics.composerPadding` | 14 | 13 | 16 |
| Composer one-line height | `appearance.metrics.composerMinHeight` | 44 | 52 | 48 |

## Theme file blocks

Paste one into a theme file (`~/.config/cmux/themes/NAME.json`) and save: the running app repaints.
A key whose change has not landed yet is reported as unknown, and the rest still applies. The web
tokens go in the look's `agent-pane/theme.css`, on `:root`, with the values in the menu table.

```jsonc
// Claude
{
  "sidebar.drawnMenus": true,
  "appearance.menu.cornerRadius": 9, "appearance.menu.borderOpacity": 0.1, "appearance.menu.shadow": "standard",
  "appearance.menu.padding": 4, "appearance.menu.rowHeight": 24, "appearance.menu.highlightRadius": 8,
  "appearance.menu.shortcuts": "muted", "appearance.menu.sectionLabel": "muted", "appearance.menu.separator": "subtle",
  "appearance.menu.destructiveInk": "standard", "appearance.menu.submenu": "flush", "appearance.menu.subtitle": "muted",
  "appearance.popover.padding": 12, "appearance.popover.header": "strong",
  "appearance.popover.progressHeight": 6, "appearance.popover.progressFill": "standard",
  "appearance.metrics": {
    "titlebarHeight": 40, "sidebarWidth": 288, "sidebarRowHeight": 26, "sidebarRowInset": 8, "sidebarRowPadding": 10,
    "sidebarRowGap": 0.5, "toolbarButtonSize": 21.5, "toolbarButtonGap": 3, "toolbarButtonCornerRadius": 5,
    "toolbarButtonActiveFill": 0.14, "headerDivider": 1, "composerPadding": 14, "composerMinHeight": 44
  }
}
```

```jsonc
// Codex
{
  "sidebar.drawnMenus": true,
  "appearance.menu.cornerRadius": 15, "appearance.menu.borderOpacity": 0.14, "appearance.menu.padding": 12.5,
  "appearance.menu.rowHeight": 28.5, "appearance.menu.highlightRadius": 8,
  "appearance.menu.shortcuts": "muted", "appearance.menu.sectionLabel": "muted", "appearance.menu.separator": "subtle",
  "appearance.menu.submenu": "flush", "appearance.menu.subtitle": "muted",
  "appearance.metrics": {
    "titlebarHeight": 46, "sidebarWidth": 306, "sidebarRowHeight": 30, "sidebarRowInset": 8, "sidebarRowPadding": 8,
    "sidebarRowGap": 1, "toolbarButtonSize": 28, "toolbarButtonGap": 6, "toolbarButtonCornerRadius": 14,
    "toolbarButtonActiveFill": 0.1, "headerDivider": 0, "composerPadding": 13, "composerMinHeight": 52
  }
}
```

```jsonc
// Studio
{
  "sidebar.drawnMenus": true,
  "appearance.menu.cornerRadius": 8, "appearance.menu.borderOpacity": 0.12, "appearance.menu.shadow": "subtle",
  "appearance.menu.padding": 4, "appearance.menu.rowHeight": 28, "appearance.menu.highlightRadius": 4,
  "appearance.menu.shortcuts": "muted", "appearance.menu.sectionLabel": "muted", "appearance.menu.separator": "subtle",
  "appearance.menu.submenu": "flush", "appearance.menu.subtitle": "muted",
  "appearance.metrics": {
    "titlebarHeight": 52, "sidebarWidth": 255, "sidebarRowHeight": 28, "sidebarRowHeightWithSubtitle": 78,
    "sidebarRowInset": 8, "sidebarRowPadding": 10, "sidebarRowGap": 2, "toolbarButtonSize": 28, "toolbarButtonGap": 4,
    "toolbarButtonCornerRadius": 6, "headerDivider": 0, "spacingScale": 1.25, "composerPadding": 16, "composerMinHeight": 48
  }
}
```

## Try it

```sh
cmux settings set sidebar.drawnMenus true    # right-click a workspace row: a drawn menu
cmux settings set sidebar.drawnMenus false   # the system menu again
```
