# cmux next: modifier keys while resizing panes and columns

Status (2026-10-27): implemented in `CmuxNextLayout` (`DividerDrag`, `DividerDragModifiers`,
`PushResize`, `StripStart`). User ask (Oct 27): "when user is resizing panes/columns, think of what we
can do if they hold cmd/option/shift/ctrl… like push things to the right instead of resizing into the
same column".

## What others do

- niri, PaperWM: a scrolling strip. Growing a column pushes the columns after it (the strip gets longer);
  nothing shrinks. Widths jump between presets (niri `switch-preset-column-width`, PaperWM Super-R).
  No modifier variants on a mouse resize.
- Hyprland, tmux: a border drag trades space between the two neighbors. Hyprland has resize submaps for
  the keyboard; tmux has `resize-pane` steps. No modifier variants on a mouse drag.
- Finder column view: Option-drag on a column resizer resizes every column at once; double-click fits.
- Figma, Sketch: modifiers change a live drag and can be pressed or let go mid-drag. Shift constrains to
  increments, Option resizes from the center, Command turns snapping off. Escape cancels a drag.
- Blender: a held key slows the drag for precision; letting it go does not jump the value back under
  the pointer.
- AppKit `NSSplitView`: no modifier modes; double-click on a divider is the common "reset".

cmux's default already follows both families: a split divider trades between its two panes (tmux,
Hyprland), a column edge grows the column and pushes the strip (niri). The modifiers flip or extend
those defaults; they never invent a third model.

## Modifier map (defaults picked; the user can override)

| Key held | Split divider | Column edge |
| --- | --- | --- |
| none | trades between its two panes, soft snaps (8 pt) at 1/3, 1/2, 2/3 and the chain's equal share | grows or shrinks the column; the columns after it move |
| Option | in a scrolling column: the column grows by the drag and the columns after it move; only the pane before the divider changes (niri's push) | trades width with the next column; the columns after it stay put |
| Command | the panes on each side of the divider stay even (`layout.splitSizing` even, applied live) | every scrolling column takes this width (Finder's all-columns drag) |
| Shift | lands only on a snap, at any distance | lands only on a preset width (1/3, 1/2, 2/3, full) |
| Control | moves at a quarter of the pointer's speed, no snapping | same |

- Command beats Option when both are held (one structural mode at a time). Control beats Shift.
  Option or Command combine with Shift or Control (Option-Shift: push, landing on snaps is not
  applied to the push; Command-Shift: every column at a preset width).
- Every frame derives its values from the drag's start, the pointer and the keys held now
  (`DividerDrag.apply`), so a key pressed or let go mid-drag switches the mode at once. A value the new
  mode stops setting goes back to its start (`LayoutModel.restoreGestureValues`) and is not sent.
- Control keeps a trail: letting it go leaves the divider where it is, not under the pointer.
- Escape cancels the drag: every value goes back to the start, nothing reaches the daemon
  (`LayoutModel.cancelGesture`). The handle watches Escape and modifier keys with a local event
  monitor only between press and release.
- While a key changes the drag, a toast at the bottom of the window names the mode
  ("⌥ Push: the column grows and moves the columns after it"); it names only modes that apply to the
  handle and goes on release. The snap haptic (`.alignment`) plays as before.
- Double-click stays: a split divider evens its chain, a column edge steps to the next preset.
- Row edges ignore the modifiers (their own fit-and-scroll rules, rows.md Z1).
- Option on a vertical divider, a `splits` screen or a docked column has nothing to push: the drag is
  a plain one and no hint shows.

Why Command and not Option for "all columns" (Finder): Option is the user's own choice for push, and
Option's flip (push for splits, trade for column edges) is the mode people reach for most. Why Control
for precision and not Shift (Blender): Shift is snapping in Figma and in this map; Control-click is a
secondary click only when pressed before the press, and the handle has no menu.

## Daemon and undo

Unchanged wire: a drag still sends only its ended values, one command per changed split or column, all
under one `LayoutTransactionID`. Option on a split sends its ratios and the column width; Command on a
column edge sends every column's width. Single-op atomicity for multi-value drags waits for
`LayoutOp` batches (column-sizing.md, agreed op shapes).

## Tests

`DividerModifierDragTests` drives the real `DividerHandleView` (press, drags with flags,
`flagsChanged`, `cancelOperation`, release) on a columns screen and a splits screen;
`DividerResizeMathTests` checks the key map, the push across nested splits, the minimums, the trade
and the uniform width.

## Later

- Guides: draw the snap positions while Shift is held (needs a line above Chromium pages, the divider
  overlay-hole path).
- Option-Shift push landing on preset column widths.
- A Settings row to turn the modes off, if anyone asks.
