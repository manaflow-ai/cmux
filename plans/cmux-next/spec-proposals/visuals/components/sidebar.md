# Sidebar

Window-height list of workspaces with pinned sections (Home at the top; Settings and Account at the bottom). A flat tonal step over the window backdrop: `sidebarStep` (the foreground at 4%) painted by `ChromeStepView` (`SidebarContainerView.swift (SidebarContainerView.backdropStep)`), no panel, no border, no seam, no borders on rows. Apple System dark: `#272727` over `#1E1E1E`. The images predate this step and show the bare window background. Width 208 compact / 240 comfortable. Sources: `Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Views/` at `d445a445556` unless noted; images from `1824883286a`. Tokens: [design-tokens.md](../design-tokens.md); JSON keys `components["sidebar.*"]`.

![Sidebar, dark, default: selected row on the shared pill, unread badge on api-server](../images/sidebar/dark-default.png) ![Sidebar, light, default](../images/sidebar/light-default.png)

## Workspace row

Row height `sidebarRowHeight` (24/32); `sidebarRowHeightWithSubtitle` (36/46) only when the row has live status. Rows are 2 pt apart (space1). Text starts at space3 (6) from the row edge, +space5 (12) when grouped; with an icon, the icon box is smallIconSize+space2 and the text starts space3 after it. Corner radius itemCornerRadius (6/7). A clipped title fades over space6 (16) at its trailing edge. Title body (12/13), bodyEmphasized when unread; subtitle caption (10.5/11).

| state | background | title | subtitle | other | source |
|---|---|---|---|---|---|
| default | none | textPrimary | textSecondary | | WorkspaceRowView.swift:117-126 (`WorkspaceRowView.updateLayer`) |
| hover | hoverFill, fading over 0.08 s (`SidebarRowView.paintFill`) | textPrimary | textSecondary | close button (x) replaces the badge; title narrows, then marquees after 0.6 s | :103-115 (`hoverChanged`), :122-124, :149-156 (`layout`) |
| selected (active) | selectionFill on one shared pill that glides between rows (spring selection 0.15/0.9) | textPrimary | textSecondary | | ChromeDecorations.swift:48-58 (`SidebarDecorationView.updateColors`, `setPill`) |
| selected + hover | selectionFill pill | textPrimary | | close button shown | |
| multi-selected (not active) | secondarySelectionFill | | | | WorkspaceRowView.swift:122-124 (`updateLayer`) |
| drop target | selectionFill; insertion gap is a hoverFill pill | | | | WorkspaceRowView.swift:122; ChromeDecorations.swift:49 |
| dragging | card elevatedBackground, radius itemCornerRadius; shadow color shadow, opacity 0.28, radius 12, y 6 (rest: 0, 4, 2); stacked cards inset 4 per depth with alpha 0.85 and a 0.5 pt separator border; count badge textPrimary fill, textOnPrimary text | | | lift fade 0.12 s, drop spring settle | DragLiftView.swift:20-107 (`DragLiftView.init`, `layout`, `setLifted`) |
| unread | | bodyEmphasized | | badge | WorkspaceRowView.swift:59 (`configure`) |
| pressed | no distinct state: selection changes on mouse down | | | | |
| keyboard focus | no ring; arrow keys move the pill | | | | |
| unfocused window | no change (only the system traffic lights dim) | | | | |
| light vs dark | same tokens; values from the theme | | | | |

![Row hover, dark: hoverFill and close button](../images/sidebar/dark-row-hover.png) ![Selected row hover, dark](../images/sidebar/dark-selected-row-hover.png) ![Unread row hover: badge hidden, close shown](../images/sidebar/dark-unread-badge-hover.png)

![Row hover, light](../images/sidebar/light-row-hover.png) ![Selected row hover, light](../images/sidebar/light-selected-row-hover.png)

Close button: iconSize+space2 (18/20) square, space3 from the trailing edge, glyph smallIconSize-space1 regular.

## Unread badge

Count pill: height iconSize (14/16), width max(height+4, text+8), radius height/2 (continuous), the count or `99+` above 99, fill badgeFill, text textPrimary in shortcut (SF Mono 10.5 medium). Dot: 6 pt, alpha(textPrimary, 0.85). Hidden while the row is hovered. Source `UnreadBadgeView.swift:47-65 (UnreadBadgeView.preferredWidth, updateLayer)`.

## Status indicator

Rows, section headers and tabs share one indicator (`CmuxNextDesign/StatusIndicator/`, `StatusIndicatorLayer`): slot smallIconSize-space1 (10/12) in rows; in tabs the icon frame inset space1. Glyph rules: `StatusIndicatorPlan.swift:63-93 (StatusIndicatorPlan.staticPlan)`. Settings: `appearance.statusIndicator.{style,size,thickness,color}`.

| state | glyph | color | motion |
|---|---|---|---|
| idle | hidden | | |
| busy | arc covering 0.72 of the circle, stroke 1.5 | textSecondary (or appearance.statusIndicator.color) | spin, 0.9 s/turn |
| busy with progress | ring over a track at 0.22 opacity | textSecondary | none |
| waiting (needs input) | dot, 0.5 of the slot | attention | pulse 1.8 s, low 0.35 |
| error | dot | danger | none |
| success | check | success | none |
| paused | dot or ring | attention | none |
| Reduce Motion | same glyphs | | no spin, no pulse |

Styles: arc (default), native (NSProgressIndicator, 8 steps), dot, braille (10 frames ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏ over the 0.9 s spinner period, in the terminal font, else SF Mono, fitted to the slot), none. `appearance.statusIndicator.honorStatusStyle` decides which reporters may pick the style. UNVERIFIED screenshot: the image build `1824883286a` predates this indicator, and no socket verb sets agent state. Diagram:

```
 busy        waiting      error       success     progress
  ◜ ⟳        ● (pulse)    ●           ✓           ◔ over ○ (track 0.22)
 textSecondary attention  danger      success     textSecondary
```

## Section headers and pinned sections

Header height sidebarHeaderHeight (22/26), text header style (11/12 semibold) in textTertiary, chevron textTertiary (smallIconSize-space2, bold) (`Sections/SidebarSectionHeaderView.swift:49-50 (updateLayer)`). Items: row height sidebarRowHeight, title textPrimary, icon textSecondary (textPrimary when active; textOnPrimary on a colored list chip).

| item state | fill | source |
|---|---|---|
| default | none (tray and grid tiles: hoverFill) | SidebarItemRowView.swift:110-127 (`SidebarItemRowView.updateLayer`, `fill`) |
| hover | hoverFill (fades 0.08 s) | :123-127 (`fill`) |
| active | selectionFill | :123-127 |
| pressed | pressedFill (wins over active) | :123-127 |
| missing target | whole item opacity 0.5 | :105 (`configure`) |

Section look: cmux.json `sidebar.sectionLook`, default quiet (`CmuxNextSettings/SidebarSectionsSetting.swift:6-22 (SidebarSectionsSetting)`). The Debug tunable `sidebar.sections.look` overrides it (`CmuxNextSidebar/Sections/SidebarSectionTunables.swift:76-91 (SidebarSectionTunables.look, currentLook)`).

| look | headers | separation | built-in items |
|---|---|---|---|
| quiet | yes | hairline band lines (separator) | rows |
| card | yes | each section on a card, hoverFill, radius itemCornerRadius+2 | rows |
| tray | yes | none | tiles in a grid (min width rowHeight*1.5, height rowHeight+4, gap 4, rest fill hoverFill) |
| lines | no | 1 pt line between sections | rows |
| linesIcons | no | lines | icon-only buttons (width rowHeight+4) |

Under borders none the lines become hoverFill at 0.6 of its alpha (`Sections/SidebarRegionView.swift:159-160 (SidebarRegionView.updateLayer)`).

Each section also has an arrangement (`CmuxNextSidebar/Sections/SectionArrangement.swift:8-45 (SectionArrangement)`; flow in `SectionFlow.swift:26-37 (SectionFlow.mode)`). The tray look forces built-in sections into a grid; linesIcons forces them inline, icons only.

| arrangement | items |
|---|---|
| list (default) | one row per item, icon and label |
| inline | chips side by side: icon at space2, label space2 after it, then the unread count badge space2 after the label when there is one; the pill fills the chip; width space2 + iconBox + space2 + label + 2 × space2, plus badge width + space2 with a count. Icons only when labels do not fit; a second line only when icons do not fit |
| grid | tiles in columns, as many as fit at rowHeight × 1.5 unless `columns` is set; `align fill` stretches them |

Gap between items: the section's `gap`, else space2. Chip geometry: `Sections/SidebarItemRowView.swift:70-77,133-162 (SidebarItemRowView.chipWidth, layout)`.

Band caps: `sidebar.topBandMaxShare` (1/3) and `sidebar.bottomBandMaxShare` (0.25) limit the pinned bands before they scroll inside; `sidebar.pinnedBandsScroll = false` keeps them fixed and shrinks the list to at least three rows.

![Section looks, dark: quiet](../images/sidebar/dark-look-quiet.png) ![card](../images/sidebar/dark-look-card.png) ![tray](../images/sidebar/dark-look-tray.png) ![lines](../images/sidebar/dark-look-lines.png) ![lines, icons only](../images/sidebar/dark-look-linesIcons.png)

![Section looks, light: quiet](../images/sidebar/light-look-quiet.png) ![card](../images/sidebar/light-look-card.png) ![tray](../images/sidebar/light-look-tray.png) ![lines](../images/sidebar/light-look-lines.png) ![lines, icons only](../images/sidebar/light-look-linesIcons.png)

![Home item hover, dark](../images/sidebar/dark-home-item-hover.png) ![Footer item hover, dark](../images/sidebar/dark-footer-hover.png)

## Icon buttons and hover card

Sidebar icon buttons: sidebarHeaderHeight square, radius itemCornerRadius (continuous), SF Symbol smallIconSize semibold, tint textSecondary (textPrimary while hovered or pressed); fills from `ChromeHover`: hover hoverFill (fades 0.08 s), pressed pressedFill, keyboard focus a 1.5 pt focusRing outline (`SidebarIconButton.swift:18-61 (SidebarIconButton)`).

Workspace hover card: glass panel (overlay material), radius panelCornerRadius, shown 0.6 s after the pointer rests on a row, offset space2 from the row (`WorkspaceHoverCard.swift:16 (WorkspaceHoverCardController.delay)`, `CmuxNextDesign/HoverCards/HoverCardPanel.swift (HoverCardPanel)`). Material: the overlay fallbacks in [design-tokens.md](../design-tokens.md#4-materials), opaque under Reduce Transparency, through `Glass.makeOverlayPanel`. UNVERIFIED screenshot: hover cards follow the real pointer through the hover coordinator; `debug.mouse action:hover` did not open one. Diagram:

```
 sidebar row  ┃ ┌──────────────────────────┐  glass, glassTint, radius 10/12
 [cmux-next ] ┃ │ cmux-next     bodyEmph.  │  padding space5
              ┃ │ ~/fun/cmux    caption    │  textSecondary
              ┃ │ CPU 2%  RAM 180 MB       │
              ┃ └──────────────────────────┘  4 pt from the row
```

## Workspace group headers

Group headers use the group colors ([design-tokens.md](../design-tokens.md#group-colors-user-content-exception)), a user-content exception to the theme-only rule. Name textSecondary, count, pin and chevron textTertiary. Hover fill hoverFill. As a drop target the row fills with the group swatch at alpha 0.16 (grey: selectionFill). A chosen color shows as a dot: filled when expanded, a 1.5 pt ring when collapsed (`GroupHeaderRowView.swift:81-103 (GroupHeaderRowView.updateLayer)`). UNVERIFIED screenshot.

## Driving states for screenshots

`debug.mouse {"action":"hover","x":X,"y":Y}` (top-left window points) delivers hover to tracking-area owners. `cmux notify --workspace N` sets unread. `debug.tunables {"action":"set","key":"sidebar.sections.look","value":"card"}` switches looks. `debug.sidebar_rename` starts inline rename. See [tools/capture.sh](../tools/capture.sh).

## Light appearance, more states

![Light: unread row hover](../images/sidebar/light-unread-badge-hover.png) ![Light: Home item hover](../images/sidebar/light-home-item-hover.png) ![Light: footer item hover](../images/sidebar/light-footer-hover.png)
