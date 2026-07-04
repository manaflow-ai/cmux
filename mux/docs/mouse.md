# Mouse

## Click targets

The sidebar shows a `workspaces` header, two rows per workspace, and `+ new workspace`. Click either row of a workspace to select it. Click `+ new workspace` to create one. Drag the sidebar's right border to set a session-local width override clamped to 10 through 60 columns.

Each pane has a border box. Click inside a pane to focus it. The top border is the tab bar: click a tab chip to select it, click `+` to create a PTY tab, click `‹` or `›` to scroll overflowing tabs, or wheel over the bar to scroll tab chips.

The status bar lists screens for the active workspace. Click a screen segment to select it. Click the trailing `+` to create a screen.

## Scrollbars

The scrollbar is visible only when a PTY surface has scrollback. With the default `scrollbar.position = "column"`, it uses a dedicated column just inside the right border. With `"border"`, it overlays the right border.

The thumb is `▕` normally and `▐` while hovered or dragged. Clicking the thumb starts a drag without moving the viewport. Clicking the track outside the thumb jumps to that relative position, then starts a drag from the clicked anchor.

Wheel over a PTY pane focuses that pane first. On the normal screen it scrolls by three rows. On the alternate screen, if the inner app is not tracking mouse input, the TUI sends three up or down arrow keys.

## Resize

Drag pane borders to resize the matching split. Dragging a corner adjusts both intersecting split axes. The ratio is clamped from 0.05 to 0.95. Outer edges that do not correspond to a split do not change layout.

## Context menus

Right-click a pane for:

- Rename tab
- New tab
- New browser tab
- Split right
- Split down
- Close tab
- Close pane

Right-click a workspace row for rename or close. Right-click a screen in the status bar for rename or close.

Menus can be used with the keyboard: Up and Down move the selected row, Enter activates it, and Esc closes the menu. A right press, drag to a row, and release activates that row. A plain right-click opens the menu and leaves it open.

## Selection and clipboard

Drag inside a PTY pane to select text. Releasing copies non-empty selected text to the host clipboard with OSC 52. The selection is viewport-anchored and clears on scroll, typing, or when the selected surface exits.

Browser panes receive left press, drag, and release as CDP mouse events instead of starting text selection.

## Pointer shape

The TUI emits OSC 22 `pointer` over clickable UI and OSC 22 `default` elsewhere. Terminals without pointer-shape support ignore it.

## Rename dialogs

Rename and browser URL prompts are centered dialogs with input, `[ Cancel ]`, and `[ OK ]`. Enter commits, Esc cancels, Backspace edits, and printable non-control characters append. Clicking OK commits; clicking Cancel or outside the dialog closes it. Right-clicking while a prompt is open shakes the dialog and does not open a context menu.
