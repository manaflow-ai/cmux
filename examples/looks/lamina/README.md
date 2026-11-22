# Lamina

A layered, translucent desktop look for cmux: the sidebar, the title area and the content sit
on separate layers of glass, controls have 4 point corners and panes and cards 8, every edge is
a one-point stroke, nothing reveals on hover, and the selected row carries an accent mark. Rows
and strips are compact.

Lamina ships as recipes in `cmux-tui/crates/cmux-customize-recipes`, not as a `cmux setup`
folder: each recipe is one profile that sets the settings, a theme file
(`recipes/apps/<variant>/theme.json` or `theme-light.json`) and a chat stylesheet
(`recipes/apps/<variant>/agent-pane.css`, shared by the variant's dark and light recipe).
The guide is [`docs/cmux-next/customize-recipes.md`](../../../docs/cmux-next/customize-recipes.md).

## The recipes

| Recipe | Variant | Accent |
| --- | --- | --- |
| `lamina` | The base: compact, balanced, frosted | `#4cc2ff` |
| `lamina-light` | The base, light | `#005fb8` |
| `lamina-mist` | Cool and more translucent: clear glass, a blue-gray tint, a card sidebar, looser density | `#4cc2ff` |
| `lamina-mist-light` | Mist, light | `#005fb8` |
| `lamina-slate` | Neutral, flatter and denser: no glass, solid layers, a line between panes | `#7aa2d6` |
| `lamina-slate-light` | Slate, light | `#3d6fa5` |
| `lamina-tide` | Accent-forward teal, a tray sidebar, a thicker status ring | `#2dd4bf` |
| `lamina-tide-light` | Tide, light | `#0f766e` |

## Install

```sh
cmux customize recipes --open        # once: writes the recipe files and opens the guide
cmux customize use ~/.local/state/cmux/customize/recipes/lamina.json
cmux customize apply                 # keep it
cmux customize discard               # or put back what you had
```

Swap `lamina` for any name in the table. `cmux customize rollback` undoes an applied recipe.
To make one your own, edit `~/.config/cmux/themes/NAME.json` and
`~/.config/cmux/agent-pane/theme.css` after you apply it.

## What each surface gets

| Surface | Keys or variables | What changes |
| --- | --- | --- |
| Window glass | `appearance.backgroundBlur`, `backgroundOpacity`, `glassTransparency`, `wallpaperTint`, `hue`, `saturation` | Frosted (Mist: clear glass, Slate: none), the layers 0.5 to 0.94 opaque |
| Colors | `colors.*`, `appearance.theme`, `appearance.accent: theme`, `appearance.highlightColor` | Layer color, ink, selection, the accent |
| Chrome | `appearance.chromeStyle`, `borders`, `titleAreaTone`, `titleAreaContrast`, `cornerFlush`, `focusIndicator`, `focus.inactiveTabStyle` | Outlined cards, a subtle tone under the title, the focused pane shown by its tab |
| Layers | `appearance.surfaces.*.color` and `.opacity`: sidebar, tabBar, terminal, agentPane, newTabPage, home, settings, internalPage, markdown, diff, editor, browserChrome, docks, splitDivider | Sidebar and docks lowest, title and tabs next, content on top, a one-point divider |
| Panes | `layout.paneCornerRadius: 8`, `paneBorderWidth: 1`, `cornerPadding`; recipe settings `layout.paneSeparation`, `layout.panePadding`, `layout.paneBorderColor` | 8 point pane corners, a one-point stroke, cards (Slate: borders) |
| Sidebar | `appearance.sidebarSurface`, `sidebar.border`, `borderWidth`, `sectionLook`, `density`, `groupHeader.background`; `appearance.metrics.sidebarRowHeight` | A one-point edge, compact rows, a section look per variant |
| Density | `appearance.density`, `appearance.metrics.titlebarHeight`, `tabStripHeight`, `tabFontSize`, `chromeFontSize`, `dividerThickness` | Compact (Slate: ultra compact, Mist: cozy) |
| Chat type | `agentPane.display.font.preset: system`, `font.ui: system-ui`, `font.size`, `font.lineHeight`, `code.scale` | The system face, 14 point text (Slate 13) |
| Status | `appearance.statusIndicator.style`, `size`, `thickness`, `color` | A thin ring in the accent (Slate: a dot) |
| Motion | `appearance.colorTransition.duration`, `curve` | 120 ms color changes |
| Radii | `--ds-radius-sm/md/control/lg/xl/2xl` in `agent-pane.css` | 4 point controls, 8 point cards, popups and code blocks, in the chat |
| Your prompt | `--cv-bubble`, `.cv-user__bubble` | An 8 point card tinted by the accent, a 1 px stroke, not a pill |
| Composer | `--acpmux-composer-*`, `--grid-composer-radius`, `--climb-shell-radius` | An 8 point card, a 1 px stroke, an accent edge on focus |
| Toast | `.ui-notice`, `--surface-toast-radius` | A squarer 8 point card with a 1 px stroke instead of a pill |
| Code and links | `--cv-code-bg`, `--cv-codeblock-ring`, `--cv-card-*`, `--cv-link` | Layer fills, one-point strokes, accent links |
| Chat inner cards | `--acpmux-strip-radius`, `-goal-`, `-stack-`, `-session-info-*-radius`, `-permission-pill-radius`, `-attach-radius` | 8 and 4 point corners |

## Not reachable from a theme or a stylesheet

- Terminal tab and button corners in the native window: only `layout.paneCornerRadius` and
  `layout.cornerPadding` reach them; the button corner (`Metrics.buttonCornerRadius`) has no key.
- The selected sidebar row's accent pill (the mark's width, side and corner): no key or variable;
  `sidebar.sectionLook` and `appearance.accent` only pick the style.
- Per-surface blur radius, and per-surface strokes: `appearance.backgroundBlur` is one choice for the window.
- A radius for the sidebar's rows (`--cmux-sidebar-row-radius`) set from a theme file.
- `layout.paneSeparation`, `layout.panePadding`, `layout.paneBorderColor` are settings, not look keys, so the recipe sets
  them; a theme file cannot.
- Menus and popovers outside the chat (native menus).
