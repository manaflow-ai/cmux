# Lamina Mist

A layered, translucent desktop look for cmux, cool and more translucent, on clear glass with a blue-gray tint. The sidebar, the title area and the content sit on separate layers, controls have 4 point corners and panes and cards 8, every edge is a one-point stroke, nothing reveals on hover, and the selected row carries an accent mark. It ships Dark (the default) and Light.

## The variants

| Theme file | Variant | Accent |
| --- | --- | --- |
| `lamina-mist` | Cool and more translucent: clear glass, a blue-gray tint, a card sidebar, looser density | `#4cc2ff` |
| `lamina-mist-light` | Mist, light | `#005fb8` |

The other Lamina looks: [lamina](../lamina), [lamina-slate](../lamina-slate), [lamina-tide](../lamina-tide).

## Install

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/lamina-mist@feat-cmux-next
cmux settings set appearance.themeFile lamina-mist-light    # lamina-mist (Dark) is the default
cmux setup remove manaflow-ai/lamina-mist-look
```

The same look is also the `lamina-mist` and `lamina-mist-light` recipes in `cmux-tui/crates/cmux-customize-recipes` (`cmux customize recipes --open`, then `cmux customize use ~/.local/state/cmux/customize/recipes/lamina-mist.json`).

## The files

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks the theme file; panes as cards, 6 point padding with a `#33414f` stroke; the sidebar grouped by folder with timestamps and no tip cards; a 900 px chat column, no minimap, changed files collapsed under each turn; a flat toast (`notifications.toast.style: "flat"`), not a glass pill |
| `themes/lamina-mist.json` | Default, Dark. Layer `#18202a`, ink `#eef3f9`, selection `#2a4a63`, accent `#4cc2ff`; clear glass, the most translucent of the four; the `card` section look; cozy density; the chat in the system face at 14 point; a thin ring in the accent |
| `themes/lamina-mist-light.json` | Light. Layer `#eef3f8`, ink `#17202b`, selection `#cfe4f6`, accent `#005fb8`, otherwise as Dark |
| `agent-pane/theme.css` | `cmux.agentPane.style/1` tokens: 4 point controls and 8 point cards, popups and code blocks; your prompt an 8 point card tinted by the accent; the composer an 8 point card with a 1 px stroke and an accent edge on focus; a squarer toast; every color mixed from the theme's own |
| `markdown/theme.css` | The Markdown viewer in the same hand: code on a faint layer with 8 px corners, headings over a one-point line, quotes on a one-point rule. Only `--cmux-md-*` properties on `:root` |

## What each surface gets

| Surface | Keys or variables | What changes |
| --- | --- | --- |
| Window glass | `appearance.backgroundBlur`, `backgroundOpacity`, `glassTransparency`, `wallpaperTint` | Clear glass, the most translucent of the four |
| Colors | `colors.*`, `appearance.theme`, `appearance.accent: theme`, `appearance.highlightColor` | Layer color, ink, selection, the accent |
| Chrome | `appearance.chromeStyle`, `borders`, `titleAreaTone`, `titleAreaContrast`, `cornerFlush`, `focusIndicator`, `focus.inactiveTabStyle` | Outlined cards, a subtle tone under the title, the focused pane shown by its tab |
| Layers | `appearance.surfaces.*.color` and `.opacity` | Sidebar and docks lowest, title and tabs next, content on top, a one-point divider |
| Panes | `layout.paneCornerRadius: 8`, `paneBorderWidth: 1`, `cornerPadding`; settings `layout.paneSeparation`, `layout.panePadding`, `layout.paneBorderColor` | 8 point pane corners, a one-point stroke, cards, 6 point padding |
| Sidebar | `appearance.sidebarSurface`, `sidebar.border`, `borderWidth`, `sectionLook`, `density`, `groupHeader.background`; `appearance.metrics.sidebarRowHeight` | A one-point edge, the `card` section look |
| Density | `appearance.density`, `appearance.metrics.*` | Cozy |
| Chat type | `agentPane.display.font.*`, `code.scale` | The system face at 14 point |
| Status | `appearance.statusIndicator.*` | A thin ring in the accent |
| Motion | `appearance.colorTransition.duration`, `curve` | 120 ms color changes, nothing slides in |

## Not reachable from a theme or a stylesheet

- Terminal tab and button corners in the native window: only `layout.paneCornerRadius` and
  `layout.cornerPadding` reach them; the button corner has no key.
- The selected sidebar row's accent pill (the mark's width, side and corner): no key or variable;
  `sidebar.sectionLook` and `appearance.accent` only pick the style.
- Per-surface blur radius, and per-surface strokes: `appearance.backgroundBlur` is one choice for the window.
- A radius for the sidebar's rows (`--cmux-sidebar-row-radius`) set from a theme file.
- The light twin's pane stroke: `layout.paneBorderColor` is a setting, not a theme key, so the
  look carries the dark one (`#33414f`); the `lamina-mist-light` recipe sets the light one.
- Menus and popovers outside the chat (native menus).
