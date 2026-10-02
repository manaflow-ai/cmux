# Panes, focus and borders

Panes sit in columns separated by columnGap (6/8). Each pane has padding (2/4), a corner radius (paneCornerRadius), a one-device-pixel border, and an overlay that draws the focus ring, the inactive dim and the attention ring. Sources: `Packages/macOS/CmuxNext/Sources/CmuxNextLayout/` at `1824883286a`. JSON keys `components["panes.*"]`.

![Two panes with the default focus indicator (both), dark](../images/panes/dark-focus-indicator-both.png)

## Pane states

| state | drawing | source |
|---|---|---|
| default | paneBorder hairline (1/scale), radius paneCornerRadius; hidden while a ring or attention ring draws | Views/PaneOverlayView.swift:192, :229 |
| focused | focus ring (below) when >1 pane and the indicator marks the border | Views/ScreenContentView.swift:255-260 |
| unfocused | tabs subtler (tabs page); optional dim: opaque contentBackground at 0.14, only when dimming is on or (borders none and indicator border) | :263; PaneOverlayView.swift:194, :230 |
| attention | ring in attention (or the notification color), width 2, blinks 2× over 3 s, then persists | PaneOverlayView.swift:200-228; CmuxNextDesign/AttentionSettings.swift |
| drop target | drop overlay (below) | |
| unfocused window | no change | |

Transitions fade over `fade.focus` (0.1 s).

## Focus ring

Width focusRing.width (1). Radius focusRing.cornerRadius, else paneCornerRadius. Color focusRing.color, else foreground at the contrast alpha. Style ring (default), glow (border at ring alpha × 0.6 plus shadow radius max(2, width×3)), or none (`CmuxNextDesign/FocusRingSettings.swift`, `PaneOverlayView.swift:119-147, 223-226`). Shown on one pane only when focusRing.showWhenSinglePane.

| focusRing.contrast | alpha | Apple dark | Apple light |
|---|---|---|---|
| subtle (default) | 0.20 | `#FFFFFF33` | `#00000033` |
| standard | 0.55 | `#FFFFFF8C` | `#0000008C` |
| strong | 0.85 | `#FFFFFFD9` | `#000000D9` |

![Ring corner, dark: subtle](../images/panes/dark-focus-ring-subtle.png) ![standard](../images/panes/dark-focus-ring-standard.png) ![strong](../images/panes/dark-focus-ring-strong.png)

![Ring corner, light: subtle](../images/panes/light-focus-ring-subtle.png) ![standard](../images/panes/light-focus-ring-standard.png) ![strong](../images/panes/light-focus-ring-strong.png)

## Focus indicator (appearance.focusIndicator)

| value | ring on focused pane | unfocused pane tabs subtler |
|---|---|---|
| both (default) | yes | yes |
| border | yes | no |
| tabs | no | yes |
| none | no | no |

![border](../images/panes/dark-focus-indicator-border.png)
![tabs](../images/panes/dark-focus-indicator-tabs.png)
![none](../images/panes/dark-focus-indicator-none.png)
![Light, both](../images/panes/light-focus-indicator-both.png)

## Borders none (appearance.borders)

Every border, hairline and separator becomes clear; the focus ring and attention width are off. With indicator `border`, the unfocused panes dim (0.14) instead (`CmuxNextLayout/Model/LayoutStyle.swift:95-100`). The agent pane bridge sets its border variables to transparent.

![Borders none, dark](../images/window/dark-borders-none.png) ![Borders none, light](../images/window/light-borders-none.png)

## Dividers and drop overlay

Divider: 1 pt visible, 7 pt hit width; hover fades in 0.08 s. Drop overlay defaults: style glassFill, spring track (0.12/0.9), grows from 3% smaller, inset space2 where a pane has no chrome, pane radius, label on targets ≥ 90 wide, color textPrimary; edge zones 28% of the pane clamped to 28-180 pt; new column zone 36 pt (`Views/DropOverlay/DropOverlayTunables.swift`). Drop overlay screenshots UNVERIFIED (needs a live drag; `debug.drop_highlight` exists and is the next step). Diagram:

```
 ┌────────── pane ──────────┐
 │ ┌──┐               ┌──┐  │  edge zone = clamp(28% of side, 28, 180)
 │ │L │   center:     │R │  │  overlay: glass fill, textPrimary line,
 │ │  │   move here   │  │  │  radius = pane radius, label if ≥ 90 pt
 │ └──┘               └──┘  │
 └──────────────────────────┘
```

## Light appearance and borders none crop

![Light: focus indicator border](../images/panes/light-focus-indicator-border.png)
![Light: focus indicator tabs](../images/panes/light-focus-indicator-tabs.png)
![Light: focus indicator none](../images/panes/light-focus-indicator-none.png)
![Dark: borders none, strips and pane edges](../images/panes/dark-borders-none.png)
