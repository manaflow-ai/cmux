# Drop-zone survey: window managers and docking libraries

Date: 2026-10-19. Sources were read from GitHub `main`/`master` raw files on this date.
"Verified" means read in source. "Unverified" means from memory or docs only.

Shape vocabulary:
- **Nearest edge** = pick the edge with min distance (same as 4 corner-to-corner triangles).
- **Center box + triangles** = a center rectangle; outside it, the corner diagonals decide the side.
- **Edge bands** = rectangles along each edge; a priority order resolves corners.

---

## Tiling window managers

### i3 — `src/tiling_drag.c` (verified)
https://github.com/i3/i3/blob/next/src/tiling_drag.c
- Side: nearest edge (`d_min` of 4 distances). Tie order: left, up, right, down.
- Bands (from the side): `sibling = max(2px, 0.30 * min(w,h))`; `parent = min(deco_height + 5px, sibling - 1)`.
  One band size for both axes (uses the short side), so bands are square-ish.
- Drop types:
  - `DT_PARENT`: `d_min < parent` AND the target is on that outer side of its parent.
    Then it walks UP while each ancestor is also on that side, and inserts next to the
    highest such ancestor. Preview: thin strip of `parent` px on the ancestor's rect edge.
  - `DT_SIBLING`: `d_min < sibling`. Preview: a `sibling`-px strip on the target edge.
    Insert as a sibling; if parent orientation differs, split the target (special case: 2 children
    of the same parent just flip the layout).
  - `DT_CENTER`: rest. Preview: target rect inset by `sibling` on all sides.
    Action: move into target (`con_move_to_target`); with `swap_modifier` held, swap.
- Self-drop: allowed only as `DT_PARENT` (move out of own parent); else no indicator.
- Hysteresis/dwell: none. Drag start threshold via `drag_pointer(..., use_threshold)`.
- Preview: a separate X window, solid rect, resized on each motion.
- Keyboard: `move left|right|up|down` (moves out of parent at edges), `swap container with`.

### sway — `sway/input/seatop_move_tiling.c` (verified)
https://github.com/swaywm/sway/blob/master/sway/input/seatop_move_tiling.c
- Drag start: `tiling_drag_threshold` (sway(5); default 9 px, unverified number), Euclidean, scaled.
- Order of checks per motion:
  1. Over a titlebar/tab bar: split into `2*n` regions; drop before/after a tab. Indicator is a
     10 px bar (`DROP_SPLIT_INDICATOR`) on the tab border. Adjacent-to-self regions are shifted so
     a no-op slot is never offered. Converts target to tabbed if needed.
  2. Parent edge: `DROP_LAYOUT_BORDER = 30 px` from the hovered leaf edge. Walk ancestors; the first
     ancestor whose layout is perpendicular to that edge (e.g. top/bottom of a horizontal row) gets
     the drop. Preview: 30 px strip clipped to the parent box. Tree-aware outer insertion.
  3. Leaf: nearest edge with band `0.30 * min(w,h)`. Preview: that band rect (not half).
  4. Center (inside all bands): **swap** with the target.
- Over own titlebar: no target (gives a cancel area).
- Insert: if edge not parallel to parent layout, `container_split` the target; new con copies a
  sibling's size fraction (not 0.5 of target).

### bspwm — `src/pointer.c`, `src/window.c` (verified)
https://github.com/baskerville/bspwm/blob/master/src/pointer.c
- Mouse move of a tiled window: **live swap** with the tiled node under the pointer on each
  motion (`move_client` -> `swap_nodes`). No zones, no preview. Motion throttled by
  `pointer_motion_interval`.
- Keyboard insertion model: preselection (`node -p DIR`, `-o RATIO`) then send window; receptacles
  are empty leaves that act as pre-built drop slots (bspwm.1 "Receptacles").
- Notable: preselect-then-place is a keyboard analog of a drop preview.

### Hyprland dwindle — `src/layout/algorithm/tiled/dwindle/DwindleAlgorithm.cpp` (verified)
https://github.com/hyprwm/Hyprland/blob/main/src/layout/algorithm/tiled/dwindle/DwindleAlgorithm.cpp
- Drag a tiled window: on release it is re-inserted at the window under the cursor.
- Side choice:
  - `smart_split=1` or `precise_mouse_move=1` (when drag): diagonals through the target's corners
    (`|dy/dx| < h/w` -> left/right, else top/bottom). Pure triangles, no center.
  - Default: split axis from aspect (`w * split_width_multiplier > h` -> side by side); side from
    the cursor half on that axis.
- `preserve_split`: keep the split axis after resize. `split_bias`: favor one child in ratio.
  New node gets `default_split_ratio` (1.0 = 50/50).
- Preview overlay during drag: none in this file (unverified elsewhere). Master layout: swap-like
  (unverified).

### Amethyst — `Amethyst/Model/MouseState.swift` (verified, partial)
- On mouse-up after a window move: `swapDraggedWindowWithDropzone` (swap with window under
  cursor). Pref "mouse-swaps-windows". `dragRaceThresholdSeconds = 0.15`. No zones, no preview.

### yabai — `src/mouse_handler.c` (verified)
https://github.com/koekeishiya/yabai/blob/master/src/mouse_handler.c
- `mouse_determine_drop_action`: center box 25%..75% on both axes (50% box) -> `mouse_drop_action`
  (`swap` default, or `stack`). Center only if the source node has 1 window.
- Outside the box: 4 triangles from the window center to the corners -> warp top/right/bottom/left
  (BSP split of the target, source goes first or second).
- Preview: `insert_feedback` border window on the target (same as manual insert feedback).
- Keyboard: `window --warp DIR` (re-insert next to neighbor), `--swap DIR`, `--stack DIR`,
  `--insert DIR` (presel).

### AeroSpace — `Sources/AppBundle/mouse/moveWithMouse.swift` (verified)
- Same monitor: swap with window under cursor. Other monitor: insert into the target's parent,
  index before/after by cursor vs target **center** projected on the parent orientation.
- No preview. Keyboard: `move DIR` (moves out of container at edge), `join-with DIR` (wrap target
  and neighbor in a new perpendicular container).

### Rectangle — `Rectangle/Defaults.swift`, `Snapping/SnappingManager.swift` (verified)
- Screen-edge snap. Edge margin 5 px each side; corner area 20 px; "short edge" area 145 px
  (picks a different action near corners on short edges). `snapBeforeReachingEdges` option.
- `priorSnapArea` is passed to compound calculations (keeps state across moves; light hysteresis).
- Preview "footprint": window-shaped overlay; border 2 px, alpha/blur/color configurable, optional
  fade and animation multiplier.
- Not a tree; transfers only "small px margin at outer screen edge".

---

## Terminals

### tmux (verified, tmux.1)
- No mouse drag of panes. Mouse drag on a border resizes.
- `join-pane`/`move-pane` `-h|-v` axis, `-b` before, `-l size`, `-f` = span full window
  height/width (root-level insertion, not split of target). This is the keyboard analog of an
  outer-edge band.

### Zellij (unverified)
- Pane move by keybind (move mode) and break/move pane between tabs (CHANGELOG #2664).
  No mouse drag-to-split found.

### WezTerm (verified, docs `keyassignment/SplitPane.md`)
- No pane drag. `SplitPane{direction, size={Percent=50} default, top_level=true}`: `top_level`
  splits the whole tab at root. `PaneSelect` mode can `SwapWithActive`.

### kitty (verified, docs `layouts.rst`)
- `move_window up|down|left|right`, layout `bias` (e.g. 50/62/70). Splits layout has
  `layout_action move_to_screen_edge`. No mouse drag-to-split found (unverified).

### Ghostty macOS — `macos/Sources/Features/Splits/TerminalSplitTreeView.swift` (verified)
- Drag a surface onto another surface. Zone: nearest edge (4 triangles), **no center**.
  Tie order left, right, top, bottom.
- Preview: accent color at 0.3 opacity filling the half of the pane on that side.
- Self-drag hides the drop zone so a release animates back. No dwell.

---

## Docking libraries and editors

### VS Code — `editorDropTarget.ts` (verified)
https://github.com/microsoft/vscode/blob/main/src/vs/workbench/browser/parts/editor/editorDropTarget.ts
- Area: editor body below the tab bar (`titleHeight` offset). Tab bar is separate (insert).
- Edge ring: dragging an editor = 10% of width / 10% of height. Dragging a whole group = 30% on the
  preferred axis, 10% on the other.
- Inside the ring = MERGE (center = 80% x 80%).
- In the ring, side is chosen by **thirds**, biased by `workbench.editor.openSideBySideDirection`:
  - prefer right: x < 1/3 -> LEFT, x > 2/3 -> RIGHT, else top/bottom by y half.
  - prefer down: y < 1/3 -> UP, y > 2/3 -> DOWN, else left/right by x half.
  So corners go to the preferred axis.
- Preview: 50% of the group on that side; 100% for merge. CSS move transition enabled after first
  frame (no initial animation).
- Modifier: Shift (mac) / Alt toggles `splitOnDragAndDrop` (no-split = whole area merges).
- Cleanup of overlay is scheduled (debounced) on drag leave, cancelled on re-enter.

### Dockview — `dnd/droptarget.ts`, `dnd/dropOverlay.ts`, `rootDropTargetService.ts` (verified)
https://github.com/mathuo/dockview/tree/master/packages/dockview-core/src/dnd
- Group: edge bands, `activationSize` default 20% (or px). Corner priority: left, right, top,
  bottom (left/right win). Rest = center.
- Preview `size` default 50%. If group width < 100 px (or height < 100 px), show a 1 px border
  line on that edge instead of a half overlay ("small" classes).
- Root (whole layout) edge target: activation 10 px, preview 20 px. With edge-group reveal:
  activation 32 px (outer sub-band = dock as edge group, inner = split grid).
- Transition 70 ms ease-out on top/left/width/height/opacity. Overlay may be mounted in a shared
  anchor container so it slides between groups; clearing is deferred one tick on dragleave.
- `PositionResolver` hook allows custom zone rules. Keyboard docking calls `showOverlay(position)`
  to draw the same preview as mouse drag.
- `_state` is reset when a target resolves to nothing, so a later drop never commits a stale
  position.

### Golden Layout — `items/stack.ts`, `items/ground-item.ts` (verified)
- Non-empty stack body: left = left 25% full height; right = right 25%; top = middle 50% width,
  upper half; bottom = middle 50% width, lower half. **No center** (center goes to the header).
  Highlight = 50% half.
- Empty stack: whole body = add.
- Root side areas: 50 px from each layout edge.
- Insert: if parent axis matches, add as sibling and halve the target (`size *= 0.5`); else wrap.

### FlexLayout — `model/DockLocation.ts`, `TabSetNode.ts`, `RowNode.ts` (verified)
- Tabset content: **center box 25%..75%** (50% box) -> CENTER (add as tab); outside: two
  diagonals pick the side (triangles). If only split allowed, triangles reach the center.
- Preview: half of the tabset (`getDockRect` = w/2 or h/2); center = full rect.
- Tab strip: `findStripDrop` -> insert index between tabs.
- Root edges: 10 px margin, and only within +-50 px of each edge midpoint when edge dock
  indicators are on (otherwise full edge). Preview = half of root.

### JetBrains IntelliJ — `TabsUtil.getDropSideFor` (verified)
https://github.com/JetBrains/intellij-community/blob/master/platform/platform-api/src/com/intellij/ui/tabs/TabsUtil.java
- `r = ide.tabbedPane.dragToSplitRatio` = **0.2** (clamped 0.05..0.45).
- 4 trapezoids: edge bands of depth r, inner corners cut by diagonals to the `(r, r)` inner box
  corners. Center = inner 60% x 60% box (drop into tabs).
- Check order: right, left, bottom, top.
- Preview: half of the editor on that side (`updateBoundsWithDropSide`).
- Tab drop tolerance 15 px (`UNSCALED_DROP_TOLERANCE`) above/below the tab header.

### Chrome tab strip — `tab_drag_controller.cc` (verified, partial)
- Drag start: 10 DIP (`kMinimumDragDistance`).
- Detach: tab stays attached while the pointer is within the tabstrip +- 15 DIP vertically
  (`kVerticalDetachMagnetism`; touch 50 DIP). This is the tear-off hysteresis.
- Insertion index by tab midpoint (unverified exact function).
- Arc / Edge split view: drag tab to page edge to split (unverified; closed source).

---

## Summary table (pane body)

| System | Shape | Edge size | Center | Corners | Preview |
|---|---|---|---|---|---|
| i3 | nearest edge | 30% of min(w,h); parent band deco+5 px | move into | nearest | band strip |
| sway | nearest edge + parent band | 30% of min(w,h); parent 30 px | swap | nearest | band strip |
| VS Code | ring + thirds | 10% (30% group, pref axis) | 80% box merge | preferred axis | 50% half |
| Dockview | edge bands | 20% | rest | L/R win | 50% half; 1 px line if <100 px |
| FlexLayout | center box + diagonals | n/a | 50% box | diagonal | 50% half |
| yabai | center box + triangles | n/a | 50% box swap/stack | diagonal | border |
| IntelliJ | trapezoid bands | 20% | 60% box | diagonal | 50% half |
| Golden Layout | 25% L/R + half T/B | 25% / 50% | none | L/R win | 50% half |
| Ghostty | nearest edge | 50% (triangles) | none | nearest | 50% half, 0.3 alpha |
| Hyprland smart | aspect diagonals | n/a | none | diagonal | none |

Root/outer edge: Dockview 10 px (32 px two-band), FlexLayout 10 px (+-50 px midpoint),
Golden Layout 50 px, sway 30 px (ancestor walk), i3 deco+5 px (ancestor walk), tmux `-f`,
WezTerm `top_level`.

---

## What transfers to cmux-next

1. **Center box 50% + diagonals for the body.** Inside the 25%..75% box = join. Outside, the
   corner diagonals pick the side. This is size-independent and has no dead corners.
   Support: FlexLayout, yabai (same 0.25/0.75 numbers), IntelliJ (60% box), Hyprland smart_split.
   Reject plain nearest-edge with no center (Ghostty) since cmux needs join.

2. **Preview = the real result: 50% half for split, full pane for join.** Draw the half that the new
   pane will take (it gets 0.5). Support: VS Code, Dockview, FlexLayout, IntelliJ, Golden Layout,
   Ghostty. Do not draw thin bands (i3/sway) for leaf splits; they lie about the result size.

3. **Small panes: switch to a line indicator.** If the pane side is < ~100 pt, draw a 1-2 pt line on
   the edge, not a half fill. Support: Dockview (100 px boundary).

4. **Outer-edge band for parent/root insertion, fixed px, not %.** A thin band (~10-30 pt) at an
   edge that is also an ancestor edge inserts at the highest ancestor on that side (walk up like
   i3 `con_on_side_of_parent` / sway). Preview = strip or half of that ancestor. Support: i3, sway,
   Dockview root (10 px), FlexLayout root (10 px), Golden Layout (50 px). Keyboard twin: tmux
   `-f`, WezTerm `top_level`.

5. **Tab bar is its own zone, decided first.** Over the tab bar: insert by tab midpoint, show a
   thin insertion bar, never offer the no-op slot next to the source tab. Use a small vertical
   tolerance (~15 pt) so the bar stays live just outside the strip. Support: sway (2n regions +
   self-skip), FlexLayout `findStripDrop`, IntelliJ 15 px tolerance, Chrome 15 DIP magnetism.

6. **Self-pane rule.** On the source pane: no join, no split if the source is its only tab (no-op);
   keep the source tab bar as a cancel area. Support: sway (own titlebar = cancel), i3 (self only
   for DT_PARENT), Ghostty (hide zone on self), yabai (center only if source has 1 window).

7. **Drag start threshold, no dwell for zones.** Start after ~4-10 pt movement (Chrome 10 DIP, sway
   ~9 px). No system uses dwell time for zone choice; keep zone resolution instant. If flicker
   at diagonals is a problem, add 4-8 pt hysteresis to the current zone (Rectangle `priorSnapArea`,
   Chrome magnetism are the only precedents).

8. **Animate the preview frame, not its first appearance.** Slide the overlay between zones and
   between panes (~70-100 ms ease-out); no animation on first show; defer clear by one frame on
   leave so it can slide to the next pane. Support: Dockview (70 ms, deferred clear), VS Code
   (transition added after first frame, scheduled cleanup).

9. **Never commit a stale zone.** Recompute the zone at drop time from the drop point (Ghostty
   `performDrop`) and reset state when the pointer resolves to nothing (Dockview `_state` reset).

10. **One resolver for mouse and keyboard.** Expose a single `resolve(point, paneRect, treeContext)
    -> DropTarget` and a `showPreview(target)` that keyboard moves also call. Support: Dockview
    `PositionResolver` + `showOverlay` for keyboard docking; bspwm presel / yabai `--insert` as
    keyboard previews.

Not recommended: VS Code "thirds with preferred axis" (adds a setting-dependent bias that users
cannot see); swap-on-center (sway, yabai, AeroSpace, Amethyst) since cmux center means join;
live swap during motion (bspwm).
