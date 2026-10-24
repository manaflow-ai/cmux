# Minimal sidebar: the rail (`sidebar.style` = `rail`)

Lawrence, 2026-10-21: "for sidebar make a minimal custom design for the sidebar that is thinner
and takes up virtually 0 horizontal space and is still very clean".

Gallery with four designs: [minimal-sidebar-gallery/index.html](minimal-sidebar-gallery/index.html).

## From first principles

What must a sidebar do when it is not being used?

1. Tell you where you are (which workspace is front).
2. Tell you what needs you (unread) and what is running (an agent working).
3. Get out of the way of the content.

Everything else (names, groups, Home, search, drag reorder, menus, the hover card) is needed
only while you use the sidebar, and then you are pointing at it. So the at-rest form only needs
1 and 2, and the full sidebar can appear on demand. The content should never move when it does:
a terminal that reflows its grid on every peek is the expensive and jarring part (the standard
hide/show already holds terminal resizes during its motion for that reason). So the full sidebar
opens *over* the content, which stays pinned beside the rail.

## Designs (gallery)

| Design | Width | Where am I | What needs me | Scales to |
| --- | --- | --- | --- | --- |
| A Hairline ticks (shipped) | 6 pt | yes | yes | ~60, then compresses |
| B Dot column | 12 pt | yes | yes | ~40 |
| C Mini avatars | 24 pt | yes, by name | yes | ~12 visible |
| D Invisible edge | 2 pt | no | roughly | any |

Recommended and shipped: **A, Hairline ticks**. It is the only one that is "virtually 0" and still
answers 1 and 2. B doubles the width for easier aim, which the open-on-rest behavior makes
unnecessary. C is a narrow sidebar, not a rail. D drops "where am I".

## Behavior

Lawrence 2026-10-21, on the first version (the whole sidebar opened on hover): "im talking about
the floating card... floating card relative to the workspace row". So:

- `sidebar.style`: `standard` (default, unchanged) or `rail`. Settings > Appearance > Sidebar Style,
  cmux.json, agent-settable.
- At rest: a 6 pt rail on the sidebar's side (left or right, `sidebar.side`). One tick per
  workspace in sidebar order; a collapsed group is one tick with its most urgent state; a gap
  between groups. Selected tick spans the rail; unread ticks take the unread color; working ticks
  are brighter than idle. Past what fits, every pitch shrinks in proportion. Nothing animates.
- Each tick stands for a row: the rail's width, one pitch tall; a group's rows touch.
- Pointing at a mark shows one small floating card for that workspace: its name, a dot for
  unread or working, and its Cmd-digit. The card's top is on the row's top; it sits exactly one
  device pixel past the rail; moving to the next mark retargets the same card, with no hide in between (the
  gaps between groups bridge). The card is the app's one hover card (`HoverCardCoordinator`),
  anchored by the sidebar list's one rule (a486): the mark's row as a band across the sidebar
  column (`HoverCardEscapeGeometry.rowBand` over `sidebarColumnOnScreen`), placement `.besideRow`.
  It stays on the visible screen; it is not separately kept inside the window.
- A click on a mark selects that workspace.
- Toggle Sidebar (its shortcut, the titlebar button, the palette) opens the full sidebar over the
  content, and closes it back to the rail. Hover never opens it. A rename opens it too.
- Cmd-1…9 hint chips (held modifier) sit beside the ticks while the rail shows.

## Code

- `SidebarLayoutStyle` and `SidebarSectionsPreferences.style` (CmuxNextDesign);
  `SidebarSectionsSetting.styleDescriptor` and parse (CmuxNextSettings).
- `SidebarRailLayout` (pure geometry: ticks and their rows) in `CmuxNextSidebar/Logic`.
- `SidebarModel.style`, `isRailOpen`, `displayWidth` (6 pt while the rail is closed),
  `contentInset` (what the content keeps beside the sidebar: the rail's 6 pt in rail style).
- `SidebarRailView` draws the ticks and feeds the pointer to `SidebarRailHoverCards` (a
  `HoverCardSource`, with `SidebarRailCardView` as its card); `SidebarContainerView+Rail` wires them.
- `SidebarRailView.cardAnchor` uses `HoverCardEscapeGeometry.rowBand` (no geometry of its own).
- `debug.pointer_hover {rail: "top"|"middle"|"bottom"|index}` and the capture tours
  `scripts/cmux-next/media/tours/rail-card-{top,middle,bottom}.json`.
- `WindowRootView+SidebarRail` swaps the content and title pins from the sidebar's edge to the
  window edge plus `contentInset` in rail style (constraints found by identifier).
- `WindowShortcutHints` takes the rail's tick frames while the rail shows.

Tests: `SidebarRailTests`, `SidebarRailHoverCardTests` (CmuxNextAppTests), `SidebarStyleSettingTests`
(CmuxNextSettingsTests).

## Not done / open

- No shadow on the open sidebar; its edge is the resize handle's resting line (none with
  `appearance.borders = none`).
- A Chromium page under the open sidebar is clipped by the existing sidebar occluder; not
  verified by hand in a tagged build.
