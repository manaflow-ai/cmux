# Tabs

Every pane has its own tab strip. Pills start on the pane's content line; the strip is the window surface unless `appearance.tabBarBackground = darker`. Sources: `Packages/macOS/CmuxNext/Sources/CmuxNextTabs/` at `1824883286a`. JSON keys `components["tabs.*"]`.

![Two panes, dark: left pane unfocused (tabs fade), right pane focused](../images/tabs/dark-strips.png)

![Two panes, light](../images/tabs/light-strips.png)

## Strip

Height tabStripHeight (28/36). Pill top = snapDown((stripHeight - tabHeight - panePadding) / 2) (`CmuxNextDesign/PaneChromeMetrics.swift:49-62`). Trailing buttons (new terminal, split right, split down) are tabHeight-4 square, 2 apart, 4 after the tabs, and reveal while the pointer is in the strip. A scrolled strip fades its edge over 24 pt. Separators between unselected neighbours: separator color, height tabHeight/2, centered in the gap.

| tabBarBackground | strip fill | source |
|---|---|---|
| window (default) | none: windowBackground shows | CmuxNextApp/PaneContentView.swift:56 |
| darker | stripBackground (mix(bg, black, 0.22/0.05)) | :56, :185 |

![Darker tab bar, dark](../images/tabs/dark-tabbar-darker.png) ![Darker tab bar, light](../images/tabs/light-tabbar-darker.png)

## Tab

Height tabHeight (24/30), max width 200/240, min (icon-only, pinned) 32/40, compact style width round(max*3/4). Pill inset 1 inside its slot, radius itemCornerRadius (6/7). Icon iconSize (14/16) at 8 from the leading edge, title body (12/13) 6 after the icon, close button 16 square at 4 from the trailing edge, 4 after the title. Title fade 20. Status dot 6. A hovered unselected tab shows its close button only when its contents are at least 68 wide.

| state | fill | title and icon | close | source |
|---|---|---|---|---|
| default (unselected) | none | textSecondary; dormant textTertiary, icon opacity 0.55 | hidden | TabCell.swift:213-219, :317 |
| hover | hoverFill | textSecondary | shown | :213 |
| selected | selectionFill | textPrimary | shown on hover | :213, :219 |
| pressed | no distinct fill (selects on mouse down) | | | |
| dragging (lifted) | solid mix(windowBackground, textPrimary, 0.08); shadow opacity 0.22, radius 6, y 2 | | | :184-186, :215-218 |
| status needsInput / success / failure / unread | dot attention / success / danger / textPrimary | | | :232-238 |
| running | spinner stroke textSecondary, width 1.5 | | | TabCell+LazyLayers.swift:15-20 |
| unfocused pane | tokens through the inactive style below | | | |
| unfocused window | no change | | | |
| disabled | n/a | | | |

Colors fade over 0.08 s (easeOut). Open grows from width 0 and alpha 0 (spring appear), close uses spring disappear, reflow spring move.

![Unselected tab hover with close button, dark](../images/tabs/dark-inactive-tab-hover.png) ![Close button hover, dark](../images/tabs/dark-close-button-hover.png)

![Selected tab hover, dark](../images/tabs/dark-selected-tab-hover.png) ![Selected tab hover, light](../images/tabs/light-selected-tab-hover.png)

## Close button

16 pt, radius itemCornerRadius-2, x glyph 7 pt with 1.3 stroke and round caps (`TabCell+LazyLayers.swift:40-67`, `TabCell.swift:347`).

| state | glyph | fill |
|---|---|---|
| default | textSecondary | none |
| hover | textPrimary | hoverFill |
| pressed | textPrimary | selectionFill |

## New tab (+) and trailing buttons

+ button: tabHeight wide, radius itemCornerRadius, glyph stroke 1.4 (`NewTabButtonView.swift`). Trailing buttons: same fills (`TabStripButtonGroupView.swift:161-162`).

| state | glyph | fill | note |
|---|---|---|---|
| default | textSecondary | none | |
| hover | textPrimary | hoverFill | 0.08 s fade |
| pressed | textPrimary | selectionFill | not animated |

![New tab hover, dark](../images/tabs/dark-new-tab-hover.png) ![New tab hover, light](../images/tabs/light-new-tab-hover.png) ![Trailing button hover, dark](../images/tabs/dark-trailing-button-hover.png)

Pressed screenshots are UNVERIFIED: a synthetic mouse-down enters AppKit's tracking loop before the capture. The pressed tokens above come from code.

## Unfocused pane tabs (focus.inactiveTabStyle)

Applies when `appearance.focusIndicator` is `tabs` or `both`, the screen has more than one pane, and the pane is not focused (`CmuxNextDesign/ChromeEmphasis.swift:30-77`). Strength 0.35 (Debug tunable). Contrast floors: primary 3.5, secondary 2.5, tertiary 2.0.

| style | textPrimary | textSecondary | selectionFill | hoverFill |
|---|---|---|---|---|
| fade (default) | mixed toward the page by 0.35, floor 3.5 | mixed, floor 2.5 | alpha × 0.65 | alpha × 0.65 |
| tonal | ← textSecondary | ← textTertiary | hoverFill alpha × 0.825 | unchanged |
| quiet | ← textSecondary | textTertiary faded by 0.175 | transparent | unchanged |

Resolved for Apple System dark: fade primary `#B0B0B0`, selection `#FFFFFF11`; tonal selection `#FFFFFF0D`; quiet selection none. All themes: `components["tabs.inactivePaneEmphasis"].resolved` in the JSON. Screenshot check (dark): selected tab in the unfocused pane is `#2D2D2D` (fade), `#292929` (tonal), `#1E1E1E` (quiet).

![Unfocused pane tabs: fade](../images/tabs/dark-inactive-pane-fade.png)
![Unfocused pane tabs: tonal](../images/tabs/dark-inactive-pane-tonal.png)
![Unfocused pane tabs: quiet](../images/tabs/dark-inactive-pane-quiet.png)
![Light: fade](../images/tabs/light-inactive-pane-fade.png)
![Light: tonal](../images/tabs/light-inactive-pane-tonal.png)
![Light: quiet](../images/tabs/light-inactive-pane-quiet.png)

## Tab hover card

Glass panel, padding 12, thumbnail tabMaxWidth × round(tabMaxWidth·10/16) radius itemCornerRadius on hoverFill, title bodyEmphasized textPrimary, subtitle caption textSecondary. Delay 0.3 s over the narrowest tabs to 0.8 s over full-width tabs; re-show window 0.7 s; slide spring panel; appear 0.12 s; hide 0.08 s (`TabHoverCardView.swift`, `TabTunables.swift:49-54`). UNVERIFIED screenshot (same reason as the sidebar hover card).

## Drag

Drag starts after 4 pt; tear-off 24 pt outside the strip; group join hysteresis 0.3; autoscroll 14 pt/s per pt inside the edge fade (`TabTunables.swift:37-48`). Drop insertion and pane drop zones: see [panes.md](panes.md). Drag screenshots UNVERIFIED (`debug.tab_drag` reports state only).

## Light appearance, more states

![Light: unselected tab hover](../images/tabs/light-inactive-tab-hover.png) ![Light: close button hover](../images/tabs/light-close-button-hover.png) ![Light: trailing button hover](../images/tabs/light-trailing-button-hover.png)

![Whole window with the darker tab bar, dark](../images/window/dark-tabbar-darker.png) ![Whole window with the darker tab bar, light](../images/window/light-tabbar-darker.png)
