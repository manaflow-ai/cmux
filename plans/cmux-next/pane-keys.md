# cmux next: pane keys (Ctrl-Shift-HJKL), one model

Status: landed 2026-11-08 (resize rule); splits and rows changed 2026-11-11 (see "Splits follow the arrow"). Owner: Chief subagent "Pane move model redesign".
User (2026-11-07): "behavior of ctrl shift hjkl is still unintuitive to me, with regards to splits and
columns, from first principles what is the most sensible way to do this? maybe there's a better
abstraction than splits and columns".

## Splits follow the arrow (2026-11-11)

User (2026-11-11): "ctrl shift hl behavior is unintuitive when i'm in a column, i think it sizes things the wrong
way?? like inside a single column?" The grow/shrink rule below made Ctrl-Shift-H on the right pane of a side-by-side
split (in a screen or inside a column) move the divider **right**: the pane got narrower, against the arrow.

Rule now, two cases:

1. **A split around the focused pane along the arrow's axis** (inside a screen, a column or a row), and a **rows-v1 row
   edge**: the nearest such divider moves **in the arrow's direction**, whichever side of it the pane is on (tmux,
   Ghostty `resize_split`). H / L never move a stacked (vertical) split; K / J never move a side-by-side one. A divider
   at its limit refuses the press; the key never falls back to the column's edge or another split.
2. **No such split** (a strip column or a dock with no side-by-side split around the pane): the grow/shrink rule below
   stays, niri's column width +/-: L / J make the column or dock wider / taller, H / K narrower / shorter.

Why the split: a divider between two panes is something a person sees and pushes; a strip column is a width (niri),
and its last column's left edge moving left on L is the column growing. Cost: a pane inside a column's split no longer
widens its column from the keyboard (drag the column edge, or focus a pane with no side-by-side split). Tests:
`KeyboardResizeSplitDividerTests` (one column split both panes, split screen, middle/last column split, stack over a
pair, middle of three, stacked column J/K, H/L never touch a stack, divider at its limit refused, rows).

The tables below describe 2026-11-08; their split and row rows are replaced by case 1.

## What Ctrl-Shift-HJKL is today

Ctrl-Shift-H/J/K/L is **Resize Pane** (`resizePaneLeft/Down/Up/Right`, aliases Ctrl-Cmd-arrows,
Ghostty's `resize_split` keys). It is not a move key. Focus is Ctrl-Cmd-HJKL / Cmd-Opt-arrows. Moving a
tab is `moveSurfaceToPane*`; moving a column is `column.moveLeft/Right`.

Two rules shipped before this change, and each was mixed:

| Date | Strip column | Split inside a screen or column | Result a person sees |
| --- | --- | --- | --- |
| before 2026-11-03 | Right grows the focused column (its own width) | Right moves the divider right | Right grows a column but shrinks the right pane of a split |
| #34123, 2026-11-03 | Right moves the divider right (trade with the neighbor) | Right moves the divider right | Right shrinks the last column, the right pane, a right dock and the last row; a pane inside a column's split can never widen its column |

The second rule is tmux's and Ghostty's ("move the divider in the arrow's direction"). It needs the person
to know on which side of the divider they stand. In a strip of columns this goes wrong often: the focused
column is usually the last one (new columns open at the end), so Right shrinks what the person looks at.

## The abstraction

The layout is already the right one, and it stays: a screen is a horizontal **strip of columns**; a
column is a vertical **stack of rows** (rows-v1); a row holds a split tree (plans/cmux-next/rows.md,
option (c), the niri/PaperWM shape). What was missing is one rule that reads the same at every level.

Every pane is a rectangle with four edges. Each edge is one of: a split divider, a column edge, a row
edge, a dock's inner edge, or the screen's own edge. The keys act on the **focused pane**, not on a
divider:

> **Ctrl-Shift-L / J make the focused pane one step wider / taller. Ctrl-Shift-H / K make it one step
> narrower / shorter.** The pane's right (bottom) edge moves. When that edge is the screen's own, its
> left (top) edge moves instead. Only the two sides of the edge that moves change size; the press back
> moves the same edge back to the same pixel.

This is vim's `Ctrl-W >` / `<` / `+` / `-`, i3's `resize grow|shrink width|height`, niri's
`set-column-width +10%` / `set-window-height +10%`, and Zellij's `Resize Increase`. It is the rule a
person can apply without looking at the tree.

The step stays 5% of the split or of the strip width. A press stops at a pane's minimum, at the strip
part the window shows, and at a dock's share cap; it never changes the model without moving a pixel
(RESIZE KEYS K1).

## Move table (one row per case)

"Grow" is Ctrl-Shift-L for width and Ctrl-Shift-J for height. "Shrink" (H / K) moves the same edge back.

| Case | Edge that moves on grow | Before (#34123) on L / J | Test row |
| --- | --- | --- | --- |
| Split screen, left pane | its right edge (divider) moves right | same | split screen, left pane |
| Split screen, right pane | its left edge moves left (pane grows) | divider moved right: pane **shrank** | split screen, right pane |
| Split screen, top / bottom pane | bottom edge down / top edge up | bottom pane **shrank** | split screen, top/bottom pane |
| Split screen, middle of three | its right edge (nearest divider on that side) | same | split screen, middle of three |
| Strip, first or middle column | its right edge; trades width with the next column; camera and other columns stay | same | strip, first/middle column |
| Strip, last column | its left edge moves left; trades with the previous column | column **shrank** | strip, last column |
| Strip, one column | its right edge (the column alone gets wider), after any split inside it | same | strip, one column; one full-width column split |
| Column split, left pane | the inner divider | same | column split, left pane of a column |
| Column split, right pane, not the last column | the **column's** right edge (the column widens; the inner split keeps its ratio, so the pane grows by its share) | moved the inner divider: pane shrank, column could not widen | column split, right pane of a middle column |
| Column split, right pane, last column | the inner divider moves left | pane shrank | column split, right pane of the last column |
| Stacked column (vertical split), top / bottom pane | bottom edge / top edge | bottom pane shrank | stacked column, top/bottom pane |
| Rows (rows-v1), upper row / last row | row edge below / row edge above | last row shrank | rows, upper/last row |
| Left dock | its inner (right) edge | same | left dock |
| Right dock | its inner (left) edge moves left: dock grows | dock **shrank** | right dock |
| Top dock | its inner (bottom) edge | same | top dock |
| Bottom dock | its inner (top) edge moves up: dock grows | Up grew it, Down shrank it | bottom dock |
| Lone pane on a split screen | none: every key is refused | same | lone pane |
| Full-height strip column, J / K | none: refused (no rows) | same | full-height column |
| Home (top page or docked Chief) | none: Home has no layout panes; the keys go to Home's own bindings | same | (no layout) |

Every row is reversible: grow then shrink, or shrink then grow, puts every pane on the same pixel
(test `thePressBackPutsEveryPaneWhereItWas`). Edges are tried nearest first: a split divider on the far
side, then the container's far edge (column, row, dock), then a split divider on the near side, then the
container's near edge. An edge at its limit refuses the press; the key never jumps to another edge.

Code: `PaneResize.change` (Packages/macOS/CmuxNext/Sources/CmuxNextBridge/PaneResize.swift).
Tests: `KeyboardResizeGrowShrinkTests` (one row per table row) and the updated keyboard resize suites.

## Checked against other tools

| Tool | Resize rule | Move rule |
| --- | --- | --- |
| tmux | `resize-pane -L/-R/-U/-D`: moves the border in that direction (the old cmux rule) | `swap-pane`, `join-pane` |
| Ghostty | `resize_split:right`: divider in that direction (the old cmux rule) | none |
| vim | `Ctrl-W >` / `<`: current window wider / narrower, whatever its place (the new rule) | `Ctrl-W H/J/K/L`: window to the far edge |
| i3 / sway | `resize grow/shrink width/height`: focused container, i3 picks the side (the new rule) | `move left/right`: into the neighbor container, or out at the edge |
| niri / PaperWM | column width +/-, window height +/- (the new rule; widths are the column's own) | `consume-or-expel-window-left/right`: into the neighbor column's stack, or out as a new column |

## Moving panes (not changed here)

Chief's brief asked for Ctrl-Shift-H/L to **move** the focused pane between columns (niri's
consume-or-expel). Default not taken, because Ctrl-Shift-HJKL is the resize key the person uses and asked
to be pixel perfect (P0 RESIZE KEYS, 2026-11-02); a move on the same keys would remove resize and leave
the complaint in place. The move model, when it gets keys of its own:

| Key (proposal) | Pane in a stack of 2+ | Pane alone in its column | At the strip's edge |
| --- | --- | --- | --- |
| Move Left / Right | leaves its stack, joins the neighbor column's stack at the same height | joins the neighbor column's stack (its column closes) | becomes a new column at that edge |
| Move Up / Down | swaps with the pane above / below in its column | refused | refused |

Reverse of a join is an expel to a new column, so Left then Right is exact only if the expel restores the
old column width (the daemon keeps the closed column's width for that). This needs a daemon operation
(`cmux-layout-reducer`: move a pane to a column at an index) and is follow-up work.

## Motion

A key resize already animates as a spring of the moving edge (SplitMotion, FRAME OWNER S1-S4) and lands
in one frame under Reduce Motion (`reduceMotionOverride`, `NSWorkspace.accessibilityDisplayShouldReduceMotion`).
This change only picks a different edge, so no motion code changed.
