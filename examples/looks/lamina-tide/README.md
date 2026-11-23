# Lamina Tide

A layered, translucent desktop look for cmux, accent-forward teal, on frosted glass. The sidebar, the title area and the content sit on separate layers, controls have 4 point corners and panes and cards 8, every edge is a one-point stroke, nothing reveals on hover, and the selected row carries an accent mark. It ships Dark (the default) and Light.

## The variants

| Theme file | Variant | Accent |
| --- | --- | --- |
| `lamina-tide` | Accent-forward teal, carded sidebar sections, a thicker status ring | `#2dd4bf` |
| `lamina-tide-light` | Tide, light | `#0f766e` |

The other Lamina looks: [lamina](../lamina), [lamina-mist](../lamina-mist), [lamina-slate](../lamina-slate).

## Install

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/lamina-tide@feat-cmux-next
cmux settings set appearance.themeFile lamina-tide-light    # lamina-tide (Dark) is the default
cmux setup remove manaflow-ai/lamina-tide-look
```

The same look is also the `lamina-tide` and `lamina-tide-light` recipes in `cmux-tui/crates/cmux-customize-recipes` (`cmux customize recipes --open`, then `cmux customize use ~/.local/state/cmux/customize/recipes/lamina-tide.json`).

## The files

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks the theme file; panes as cards, 4 point padding with a `#2b4240` stroke; the sidebar grouped by folder with timestamps and no tip cards; a 900 px chat column, no minimap, changed files collapsed under each turn; a flat toast (`notifications.toast.style: "flat"`), not a glass pill |
| `themes/lamina-tide.json` | Default, Dark. Layer `#141f1f`, ink `#eef6f5`, selection `#1f4a47`, accent `#2dd4bf`; frosted glass, the layers up to 0.9 opaque; the `card` section look; compact density; the chat in the system face at 14 point; a thicker ring in the accent |
| `themes/lamina-tide-light.json` | Light. Layer `#f1f6f5`, ink `#14201f`, selection `#c4e6e1`, accent `#0f766e`, otherwise as Dark |
| `agent-pane/theme.css` | `cmux.agentPane.style/1` tokens: 4 point controls and 8 point cards, popups and code blocks; your prompt an 8 point card tinted by the accent; the composer an 8 point card with a 1 px stroke and an accent edge on focus; a squarer toast; every color mixed from the theme's own |
| `markdown/theme.css` | The Markdown viewer in the same hand: code on a faint layer with 8 px corners, headings over a one-point line, quotes on a one-point rule. Only `--cmux-md-*` properties on `:root` |

## What each surface gets

| Surface | Keys or variables | What changes |
| --- | --- | --- |
| Window glass | `appearance.backgroundBlur`, `backgroundOpacity`, `glassTransparency`, `wallpaperTint` | Frosted glass, the layers up to 0.9 opaque |
| Colors | `colors.*`, `appearance.theme`, `appearance.accent: theme`, `appearance.highlightColor` | Layer color, ink, selection, the accent |
| Chrome | `appearance.chromeStyle`, `borders`, `titleAreaTone`, `titleAreaContrast`, `cornerFlush`, `focusIndicator`, `focus.inactiveTabStyle` | Outlined cards, a subtle tone under the title, the focused pane shown by its tab |
| Layers | `appearance.surfaces.*.color` and `.opacity` | Sidebar and docks lowest, title and tabs next, content on top, a one-point divider |
| Panes | `layout.paneCornerRadius: 8`, `paneBorderWidth: 1`, `cornerPadding`; settings `layout.paneSeparation`, `layout.panePadding`, `layout.paneBorderColor` | 8 point pane corners, a one-point stroke, cards, 4 point padding |
| Sidebar | `appearance.sidebarSurface`, `sidebar.border`, `borderWidth`, `sectionLook`, `density`, `groupHeader.background`; `appearance.metrics.sidebarRowHeight` | A one-point edge, the `card` section look |
| Density | `appearance.density`, `appearance.metrics.*` | Compact |
| Chat type | `agentPane.display.font.*`, `code.scale` | The system face at 14 point |
| Status | `appearance.statusIndicator.*` | A thicker ring in the accent |
| Motion | `appearance.colorTransition.duration`, `curve` | 120 ms color changes, nothing slides in |

## Not reachable from a theme or a stylesheet

- Terminal tab and button corners in the native window: only `layout.paneCornerRadius` and
  `layout.cornerPadding` reach them; the button corner has no key.
- The selected sidebar row's accent pill (the mark's width, side and corner): no key or variable;
  `sidebar.sectionLook` and `appearance.accent` only pick the style.
- Per-surface blur radius, and per-surface strokes: `appearance.backgroundBlur` is one choice for the window.
- A radius for the sidebar's rows (`--cmux-sidebar-row-radius`) set from a theme file.
- The light twin's pane stroke: `layout.paneBorderColor` is a setting, not a theme key, so the
  look carries the dark one (`#2b4240`); the `lamina-tide-light` recipe sets the light one.
- Menus and popovers outside the chat (native menus).
