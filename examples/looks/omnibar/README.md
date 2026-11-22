# Omnibar

Browser chrome for agents and terminals: one band, one colour, one root corner. Omnibar v0.1 is
the look that goes with the design proposal of the same name (RFD 0033). It changes no default.

cmux holds many live sessions at once, the way a browser holds many live pages. Omnibar draws it
that way: a tab strip and a toolbar at fixed heights, one chrome colour with a neutral highlight on
the selected tab and row, hairlines where two regions meet, no glass, no goo, no two-tone. Every
corner comes from the address field's 8 pt. It ships Light (the default) and Dark, in Hush's
colours flattened to one tone.

It is built only from public surfaces, so you can copy any part of it:

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks the theme file; the address field at 28 pt with 8 pt corners and 14 pt text, no shadow; the chat in the system face at 14 px on a 1.5 line, code at 0.92, a 720 px column; the sidebar as a vertical tab strip: one-line rows with an icon, the title and the session's state |
| `themes/omnibar.json` | Default, Light. Every surface `#FDFCF8`, text `#2A2825`, selection `#E9E5DC`, accent `#4A65A3`, hairline `#E2DED3`, no glass |
| `themes/omnibar-dark.json` | Dark. Every surface `#222424`, text `#E3E2E2`, selection `#3D4040`, accent `#6682C2`, hairline `#373A3A` |
| `agent-pane/theme.css` | A prompt bubble with 14 px corners (the text at 6%), cards at 4% with a 10% hairline, secondary text at 76% and 70%, links in the accent a step toward the text, and menus as the address field's popup (pending, below): `cmux.agentPane.style/1` tokens only, every colour mixed from the theme's own |
| `markdown/theme.css` | Semibold headings with no rule, code on a 4% fill with 8 px corners, quotes on a hairline. Only `--cmux-md-*` properties on `:root` |

## The numbers and where they come from

| Value | Omnibar | Source |
| --- | --- | --- |
| Control height (toolbar button, address field, sidebar row) | 28 pt | Helium's default density: `kToolbarButtonHeight` and `kLocationBarHeight` 28 ([layout-constants.patch](https://github.com/imputnet/helium/blob/main/patches/helium/ui/layout-constants.patch)); cmux's row today |
| Band height (tab strip, toolbar) | 36 pt = 28 + 4 + 4 | Helium's strip is 34 (28 + 3 + 3) on a 3 pt unit; cmux's unit is 4 |
| Root corner (address field, button, row) | 8 pt | Helium: field and toolbar button radius 8 ([location-bar.patch](https://github.com/imputnet/helium/blob/main/patches/helium/ui/location-bar.patch), [toolbar.patch](https://github.com/imputnet/helium/blob/main/patches/helium/ui/toolbar.patch)) |
| Chip inside the field | 6 pt = 8 - 2 | Helium: "location bar rounding is 8px and padding is 2px, so inner rounding is 6px" |
| Pane, menu and popup corner | 12 pt = 8 + 4 | Helium's popup radius 12 ([omnibox.patch](https://github.com/imputnet/helium/blob/main/patches/helium/ui/omnibox.patch)); Chromium's menu radius 12 ([layout_provider.cc](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/ui/views/layout/layout_provider.cc)) |
| Tab width | 192 at most, 96 selected at least, 56 otherwise | Helium's 190; Chromium's close button stays on the selected tab and hides under 68 ([tab.h](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/ui/views/tabs/tab.h)) |
| Selected tab | the one second tone | Chromium: the selected tab is the toolbar's colour ([tab_strip_color_mixer.cc](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/ui/color/tab_strip_color_mixer.cc)) |
| Hover fill | the text at 6% (Light), 10% (Dark) | Chromium's toolbar hover: `0x0F` and `0x1A` alpha ([sys_color_mixer.cc](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/ui/color/sys_color_mixer.cc)) |
| Colour change | 200 ms, ease out | Chromium's tab layout and address field hover, 200 ms ([tab_container.cc](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/ui/views/tabs/tab_container.cc)) |

```sh
cmux setup install ./examples/looks/omnibar
cmux settings set appearance.themeFile omnibar-dark    # omnibar (Light) is the default
cmux setup remove manaflow-ai/omnibar-look
```

## What a look cannot set yet

Each of these is a value the system names and the build has no key for. They stay as comments in
the files, naming the change that would add them; none is faked with a selector.

| Value | Wanted | Waiting on |
| --- | --- | --- |
| Tab shape: 8 pt top corners, 4 pt foot | `appearance.tabShape` | cmux#46780 |
| Sidebar row inset 4, padding 8, 8 pt corners | `appearance.metrics.sidebarRow*` | cmux#46861, cmux#47048 |
| Toolbar button 28 square, 8 pt corners, 4 apart, hover 6% and 10% | `appearance.metrics.toolbarButton*` | cmux#46861, cmux#47048 |
| Composer: 40 pt field, 14 pt corners, 28 pt buttons 6 pt in | `agentPane.composerLook`, composer metrics | cmux#46738 |
| Menus: 12 pt corners, 28 pt rows, 8 pt highlight | `--menu-*` | cmux#46846, cmux#47046 |
| Tool-call rows: 12 px label, 12 px mono command on a 16 px line | tool row type tokens | cmux#46778 |
| Button and field corners from one root | corner tokens | cmux#49622 |
| Popup, toast and dialog corners apart from the pane's | no key | none yet |
| Any shadow or elevation step | no key | none yet |
| Comfortable density's 34 pt control in a 42 pt band | drawn by density, not by a look | none yet |
