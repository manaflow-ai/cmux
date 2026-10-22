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

- `sidebar.style`: `standard` (default, unchanged) or `rail`. Settings > Appearance > Sidebar Style,
  cmux.json, agent-settable.
- At rest: a 6 pt rail on the sidebar's side (left or right, `sidebar.side`). One tick per
  workspace in sidebar order; a collapsed group is one tick with its most urgent state; a gap
  between groups. Selected tick spans the rail in the primary text color; unread ticks take the
  unread color; working ticks are brighter than idle. The rail never scrolls: past what fits,
  every pitch shrinks in proportion down to a 1 pt tick. Nothing animates at rest (0 frames).
- Open: rest the pointer on the rail for 150 ms (a pass to the window edge does not open it), or
  click it, or a rename/reveal. The full sidebar opens at the user's width over the content on
  the sidebar's width motion (`Motion.sidebar`: Reduce Motion and the animation switches make it
  one frame). The open sidebar has the window's surface fill so it reads over the content.
- Close: 350 ms after the pointer leaves, unless the person is busy there (a mouse button down,
  i.e. a drag; a menu tracking; a field being edited), which waits another 350 ms.
- Clicking a tick selects that workspace.
- Cmd-1…9 hint chips (held modifier) sit beside the ticks while the rail is closed.
- The sidebar toggle hides everything, rail included; shown again, the rail is back.
- Home, groups, drag reorder, the hover card and the footer search button are the full sidebar's,
  unchanged, one hover away.

## Code

- `SidebarLayoutStyle` and `SidebarSectionsPreferences.style` (CmuxNextDesign);
  `SidebarSectionsSetting.styleDescriptor` and parse (CmuxNextSettings).
- `SidebarRailLayout` (pure geometry) and `SidebarRailPeek` (pure open/close reducer) in
  `CmuxNextSidebar/Logic`.
- `SidebarModel.style`, `isRailOpen`, `displayWidth` (6 pt while the rail is closed),
  `contentInset` (what the content keeps beside the sidebar: the rail's 6 pt in rail style).
- `SidebarRailView` draws the ticks; `SidebarRailPeekDriver` runs the reducer with two one-shot
  `DemandTimer`s and a hit-transparent tracking view; `SidebarContainerView+Rail` wires them.
- `WindowRootView+SidebarRail` swaps the content and title pins from the sidebar's edge to the
  window edge plus `contentInset` in rail style (constraints found by identifier).
- `WindowShortcutHints` takes the rail's tick frames while the rail shows.

Tests: `SidebarRailTests` (CmuxNextAppTests), `SidebarStyleSettingTests` (CmuxNextSettingsTests).

## Not done / open

- Dwell and grace are constants, not Debug Settings tunables yet.
- No shadow on the open sidebar; its edge is the resize handle's resting line (none with
  `appearance.borders = none`).
- A Chromium page under the open sidebar is clipped by the existing sidebar occluder; not
  verified by hand in a tagged build.
