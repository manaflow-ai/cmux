# Drop zones: one model for tab drops and pane drags

Status: landed in part, 2026-10-19 (Chief subagent "Pane drop zones redesign").
Order (user 2026-10-19): "The drop zones for split ... the drop zones for the tabs are not very
good. We want to match the drop zones for split better. Think from first principles ... see how
[open-source window managers'] logic is applicable to our pane manager."
Survey of 20 systems, with source links: [SURVEY.md](SURVEY.md). Earlier lane:
cmuxterm-hq `.cmux-scratch/pane-drop-targets/DESIGN.md` (Oct 14, commits 924a022d9a5, 64179986f90).

## 1. Audit (feat-cmux-next 9d06b973462)

Code: `CmuxNextLayout/Geometry/DropZoneGeometry.swift` (rule), `Views/ScreenContentView+TabDrop.swift`
(preview), `Views/LayoutRootView+TabDrop.swift` (overlay, dwell), `CmuxNextApp/Drag/TabDropTargets.swift`
(App adapter), `CmuxNextApp/PaneSwapDrag.swift` (pane drag), `CmuxNextTabs/TabStripView+DropTarget.swift`.

Targets a dragged tab can reach, in the order the drag session asks them:

| Target | Hit area | Preview | Result |
| --- | --- | --- | --- |
| Sidebar row / gap | row middle / row edge, gap after 0.25 s dwell | row light / gap | into workspace / new workspace |
| Tab strip | the strip, insert index by tab midpoint | 2x20 pt accent caret in the opened gap | insert at index |
| Window edge (dock) | 24 pt band (top 32 pt below the tab bar); sides 12 pt | 30% band of the screen | new dock |
| Column gap | 36 pt centered on each gap | gap rect | new column |
| Pane edge | band per edge of the body below the tab bar | final layout: new pane filled, resized panes outlined | split, new pane 0.5 |
| Pane center | the rest of the body | body inset 4 pt, accent 0.25 + 2 pt border | join (append) |
| Pane drag (cx-8bv1j, by empty strip space) | the pane under the pointer | **a 2x20 pt caret at the pane's left edge** | swap |

The band rule before this change: 25% of the extent, clamped to 40...120 pt, at most a third;
corner = relatively nearest edge; 12 pt hysteresis; split dwell 0 s.

| body extent (pt) | classic (Bonsplit) band | before: band (share) | before: center | now: band | now: center |
| --- | --- | --- | --- | --- | --- |
| 120 | 80 (no center) | 40 (33%) | 40 | 40 (33%) | 40 |
| 160 | 80 (no center) | 40 (25%) | 80 | 48 (30%) | 64 |
| 300 | 80 | 75 (25%) | 150 | 75 | 150 |
| 600 | 150 | 120 (20%) | 360 | 150 | 300 |
| 860 | 215 | 120 (14%) | 620 | 215 | 430 |
| 1200 | 300 | 120 (10%) | 960 | 300 | 600 |
| 1600 | 400 | 120 (8%) | 1360 | 400 | 800 |
| 2400 | 600 | 120 (5%) | 2160 | 600 | 1200 |

Problems found:

1. **Big panes barely split.** On a full-window pane (1200-1600 pt) the edge band was 120 pt, 8-10%
   of the pane, while the preview for that edge fills half of it. The pointer sits inside the
   half the preview just showed, moves 130 pt inward, and the drop joins. Classic cmux (Bonsplit)
   split from the outer quarter. This is the main "does not match split" gap.
2. **The pane drag shows the wrong preview.** `PaneSwapDrag` reused `showTabDragOutline`, which
   since Oct 14 draws the tab-bar caret, so dragging a pane onto another showed a 2 pt bar at the
   target's left edge instead of the target.
3. **Pane drag has no edge zones.** A pane drag only swaps; a tab drag splits. Two models for one
   gesture family. (Needs a daemon command: section 4.)
4. **No parent-level insertion.** Every edge splits the leaf. i3, sway, Dockview, FlexLayout and
   Golden Layout all have an outer band that inserts beside an ancestor. cmux-next has this only at
   the window (docks) and between columns (column gaps).

## 2. What transfers from other managers (SURVEY.md, "What transfers")

- **Center box + diagonals** (FlexLayout and yabai 25..75%, IntelliJ 60% box, VS Code ring): the
  middle half of each axis joins, the diagonals pick the side. Our band = 25% with the
  relative-nearest-edge corner rule is exactly this shape for every pane above ~190 pt.
- **Preview = result** (VS Code, Dockview, FlexLayout, IntelliJ, Ghostty): already ours, and
  stronger (the final layout, not a half).
- **No dwell, small hysteresis** (no system uses time; Rectangle and Chrome hold the prior zone).
- **Tab bar first, insert by midpoint, skip no-op slots** (Chrome, sway, FlexLayout): already ours.
- **Thin fixed-size outer band for parent/root insertion** (i3 title+5 px, sway 30 px, Dockview and
  FlexLayout 10 px root, Golden Layout 50 px): follow-up (section 4).
- **One resolver for mouse and keyboard** (Dockview, bspwm presel, yabai `--insert`): follow-up.
- Rejected: swap on center (sway, yabai, AeroSpace, Amethyst), since center means join for a tab;
  VS Code's preferred-axis thirds (an invisible setting changes the zones); bspwm live swap.

## 3. The model (first principles)

1. **The preview is the result.** What shows at release is what happens, for any pointer speed.
   No time rule (dwell 0), the zone is recomputed at release from the drop point.
2. **Zones follow the result's geometry.** A split gives the new pane half of the target; the zone
   that makes it is the outer half of that half (25% of the extent). So the pointer is always
   inside the area the preview fills, on every pane size. A cap broke this on big panes.
3. **Every target stays reachable.** Edges at least 48 pt (Fitts: hard to hit below ~40 pt) and at
   most a third of the extent, so the center keeps at least a third of each axis.
4. **Corners split on the diagonal** (relative depth), the same shape at every size.
5. **No flicker.** Shown panes, docks and gaps hold 12 pt past their lines; docks and gaps shrink for entry from the split zone that faces them.
6. **One preview per outcome.** Join is the body fill, for a tab dropped in a pane center and for a
   pane dragged onto a pane (swap). The caret is only for a tab bar slot.

Defaults picked (no user input needed): band 25%, floor 48 pt, no cap (Debug Settings
`drop.edgeMaximum` 0 = none, still tunable), hysteresis 12 pt, dwell 0.

## 4. Landed and left

Landed (feat-cmux-next, no PR): the band rule (floor 48, no cap) and the shared join preview for
pane drags, with failing-first tests `DropZoneRuleTests` and
`PaneSwapDragTests.theTargetPanePreviewsItsBody`.

Left, in order of value:

1. **Pane drag edges.** Dragging a pane onto another pane's edge moves it there (center keeps the
   swap). Needs a daemon `move-pane-to-split` (one atomic, undoable command; today there is only
   `move-tab-to-split` and `move-tab-group-to-split`). Then `PaneSwapDrag` calls
   `updateTabDrag`'s resolver, and both drags run one rule.
2. **Parent-level band.** A 16 pt band at a pane edge that is also an ancestor's edge inserts beside
   the highest such ancestor (i3/sway walk), previewed as that ancestor's final layout. Needs a
   daemon split-at-node command.
3. **Small pane line indicator** below ~100 pt (Dockview).
4. **Keyboard move** with the same preview (tmux `join-pane`, bspwm presel): Cmd+Shift+arrow over
   the resolver.
