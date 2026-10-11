# cmux-next borders: one switch

User request (2026-10-02): "make it possible to configure so there are no
borders at all anywhere in app."

`appearance.borders` in cmux.json (`default` | `none`), in Settings
(Appearance > Borders) and in Debug Settings (Shape and Icons > Borders,
an override). `none` removes every border, hairline and separator; spacing
and alignment do not move (lines keep their space and draw clear; the
3/3 pt tab gaps and the 4 pt terminal inset stay).

## The API (keep it small; every new stroke uses it)

| Use | Call |
| --- | --- |
| A border or stroke width | `Metrics.lineWidth(width)` (0 under `none`) |
| A separator or border color | `Palette.separator`, `Palette.paneBorder` (clear under `none`), or `Borders.color(color)` for any other color |
| Whether to draw a line at all | `Borders.drawsLines` |
| A SwiftUI separator | `HairlineDivider(color:)` instead of `Divider()` |
| An AppKit separator | `HairlineView` instead of a separator `NSBox` |
| Pane chrome | `LayoutStyle.drawsLines` (from `applyingDesignMetrics`) |

`Borders` (CmuxNextDesign) reads the Debug Settings override, else
`DesignSettings.shared.borders`; reading it in an observed scope tracks
the setting. `AppServices.observeBorders()` calls `ThemeStore.shared.repaintAll()`
on a change, so open windows repaint live. `Borders` is a value (`Borders(mode:)`, the pure rule); `Borders.current` is the live one.

## What `none` removes, and the replacements

| Source | Under `none` |
| --- | --- |
| Pane content border (`layout.paneBorder`) | `Metrics.paneBorder` is `.none` |
| Focus ring and glow | off; the focus cue is the unfocused panes' subtler tabs (`appearance.focusIndicator` tabs or both, the default), or their dim (`inactivePaneDimming`, 0.14) when the indicator is `border` |
| Pane unread (attention) ring | width 0; the sidebar unread badge stays |
| Split divider idle lines | hidden (`showsDividerLine`); the hover and drag line stays as resize feedback |
| Tab separators, sidebar and titlebar lines, palette rules, browser toolbar separator, page info and popup separators, onboarding hairlines | `Palette.separator` clear |
| Overlay panel edge (`OverlaySurface` fallback), drag lift, terminal status banner and copy-mode badge, tab profile and theme dots, omnibar and page-info focus rings, browser focus-mode outline | `Metrics.lineWidth` 0 |
| Settings window, history and bookmark dividers | `SettingsStyle.separator` clear, `HairlineDivider` |
| CEF DevTools divider | `Borders.color` |
| Agent pane CSS `--border`, `--border-strong` | `transparent` |
| Colorless tab profile dot | a faint fill instead of the ring |
| Pane flash (identify) | a soft fill instead of the 3 pt ring |

Kept on purpose: color swatch selection rings (they mark the chosen color,
not an edge), the copy-mode cursor box (a cursor), drop overlay lines (drag
feedback), NSMenu separators and the system's own window and Liquid Glass
edges (AppKit draws them).
