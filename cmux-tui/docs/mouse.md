# Mouse

## Click Targets

The files sidebar view (`sidebar.view = "files"`) shows the focused pane's cwd, one row per directory/file, and a count or filter footer. A single click selects a file row. Crossterm's mouse events do not expose an existing double-click concept here, so clicks do not open or descend; use Enter or Right while the sidebar is focused. Toggle to the workspaces view with focused-sidebar `Tab` or the `toggle-sidebar-view` action.

The workspaces view shows a `workspaces` header, two rows per workspace, and `+ new workspace`. Click either row of a workspace to select it. Click `+ new workspace` to create one. Drag the sidebar's right border in either built-in view to set a session-local width override. Configured `sidebar.max_width` limits the drag width when it is greater than zero, and the TUI still leaves at least 40 columns for panes.

Each pane has a border box. Click inside a pane to focus it. The top border is the tab bar: click a tab chip to select it, click `+` to create a PTY tab, click `‹` or `›` to scroll overflowing tabs, or wheel over the bar to scroll tab chips while keeping the active tab visible.

The status bar lists screens for the active workspace. Click a screen segment to select it. Click the trailing `+` to create a screen.

## Drag Reorder

Drag a tab chip to reorder it within the same pane. Drag it to another pane's tab bar to move the tab across panes. The dragged tab is dimmed, and the target insertion point is shown with a `▌` marker.

In the workspaces view, drag a workspace entry to reorder workspaces. The drop position is shown with a horizontal `─` marker.

## Scrollbars

The scrollbar is visible only when a PTY surface can scroll. With the default `scrollbar.position = "column"`, it uses a dedicated column just inside the right border. With `"border"`, it overlays the right border.

The thumb is `▕` normally and `▐` while hovered or dragged. Clicking the thumb starts a drag without moving the viewport. Clicking the track outside the thumb jumps to that relative position, then starts a drag from the clicked anchor.

Wheel over a PTY pane focuses that pane first. When the inner app enables terminal mouse tracking, wheel events are forwarded at the pointer position using the app's requested mouse protocol. Otherwise, the normal screen scrolls by three rows and the alternate screen receives three up or down arrow keys.

## Resize

Drag pane borders to resize the matching split. Dragging a corner adjusts both intersecting split axes. The ratio is clamped from 0.05 to 0.95. Outer edges that do not correspond to a split do not change layout.

Drag the sidebar border to resize the sidebar for the current TUI session. The configured base width still comes from `sidebar.width`.

## Context Menus

Right-click a pane for rename tab, close tab, new tab, new browser tab, browser actions when applicable, split right, split down, close pane, and ID copying. The menu separates current-tab, creation, browser, pane-layout, and ID actions. When an inner PTY app enables mouse tracking, right-click is forwarded to the app; hold Shift while right-clicking to open the cmux menu. Right-click a workspace row for rename, close, or ID copying. Right-click a screen in the status bar for rename or close.

Menus draw bordered overlays. Divider rows collapse as needed to keep every action visible when the flat menu would fit. Up and Down move the selected row, Enter activates it, and Esc closes the menu. A right press, drag to a row, and release activates that row. A plain right-click opens the menu and leaves it open.

## Selection and Clipboard

Clicks, releases, and motion inside a PTY pane are forwarded when the inner app enables terminal mouse tracking. cmux uses Ghostty's encoder so X10, UTF-8, SGR, URxvt, and SGR pixel modes follow the app's terminal state. Hold Shift to bypass mouse reporting and use cmux text selection.

Drag inside a PTY pane to select text when mouse tracking is disabled or Shift is held. Releasing copies non-empty selected text to the host clipboard with OSC 52. The selection stores absolute scrollback rows, so it remains stable while the viewport scrolls.

Holding a selection drag at the top or bottom content edge auto-scrolls and extends the selection. Typing clears the selection. If the selected surface exits, the selection is cleared.

Browser panes receive left press, drag, and release as CDP mouse events instead of starting text selection.

## Pointer Shape

The TUI emits OSC 22 `pointer` over clickable UI and OSC 22 `default` elsewhere. Terminals without pointer-shape support ignore it.

## Rename and URL Dialogs

Rename and browser URL prompts are centered bordered dialogs using the same `TextInput` editor. Buttons are labeled with shortcuts: `[ Clear ^C ]`, `[ Cancel esc ]`, and `[ OK ⏎ ]`.

Enter commits. Esc cancels. Ctrl-C clears. Home and Ctrl-A move to the start. End and Ctrl-E move to the end. Alt-Left and Alt-B move one word left. Alt-Right and Alt-F move one word right. Backspace deletes left, Delete and Ctrl-D delete right, Ctrl-W and Alt-Backspace delete a word left, Alt-D deletes a word right, Ctrl-K deletes to the end, and Ctrl-U deletes to the start.

Click OK to commit, Clear to clear, Cancel or outside the dialog to close, and the input row to move the cursor. Right-clicking while a prompt is open shakes the dialog instead of opening a menu.
