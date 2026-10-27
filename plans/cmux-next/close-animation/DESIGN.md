# Close motion: a whole pane, a whole window

Lawrence 2026-10-19: "Animation for closing a pane and closing a window needs to be written from
first principles. Let me know if it's the last tab of a pane. We don't need to animate the tab
closing." Chief's brief: the last tab of a pane closes the whole pane with motion (the siblings
spring into its space together, one layout pass, terminals resize once at the end); a window close
animates the whole window; a tab that is not the last closes at once; Reduce Motion closes at once.
Same spring and geometry as the split ([split DESIGN.md](../split-spring-animation/DESIGN.md)).

Tests: `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/PaneCloseMotionTests.swift`.

## Before

- **Tab that is not the last.** Instant already: the strip's close tween runs only with
  `ui.animations.newTab` on, which is off by default (`TabStripView+Sync.swift`). No change.
- **Last tab of a pane.** The tab left the strip in the key's turn (`pendingClosed`), but the pane
  stayed in the layout, empty, until the daemon's tree without it came back (one round trip, about
  100 ms, more with a browser's `prepareClose`). Then its host went at once and the neighbours
  sprang on `exit` (0.24 s, critically damped). So the key showed an empty pane for ~100 ms, then
  a second, separate motion.
- **Close Pane.** The same, from the `close-pane` command.
- **Window.** No motion: `performClose` closed the window in the same turn.

## Principles

1. **The key answers in its frame.** The person closed the pane; the window shows it gone in the
   frame of the key, not one daemon round trip later. As for a split, the change and the sizing it
   implies (`layout.splitSizing` even: the chain shares the space again, `CloseSizing`) are one
   gesture with one target, so the motion is one spring from the key's frame.
2. **A close is a split run backwards.** Same spring (`split`, 0.28 s, damping 0.95: a third of the
   way at 50 ms, at rest by ~375 ms, overshoot under 0.1 pt), same geometry (every edge
   interpolates the layout; the neighbours grow toward each other into the space). The closed
   pane's content goes at once (`closeGrowsTheNeighbourLiveAndReleasesTheClosedHost`): a pane
   that is closed does not stay on screen as a ghost.
3. **The PTY resizes once.** The neighbours are laid out live at their spring rects (Lawrence
   2026-10-18, "content must move while it animates"), so the text reflows with them on screen, but
   their terminals' grids go to the PTY once, at rest: the shell gets one SIGWINCH, not one per echo.
4. **The daemon still decides.** Nothing is sent before the close: the close command goes as
   before, the layout only hides the pane locally. A refused close brings the pane and its sizes
   back at once. The sizing intents go when the daemon's tree has lost the pane
   (`applyCloseSizing`, as before), and the echo shows what already shows.
5. **A window leaves as a whole.** It fades out from the key's frame; the keys go to the next window
   at once and the fading window takes no click, so nothing reaches a window that is leaving. Its
   state closes when the fade ends.
6. **Reduce Motion** (or the animation speed "off", or `ui.paneAnimations` off for panes): closed
   in one frame, no hold, no fade.

## Implementation

- `LayoutModel.showPaneClose(_:)` (`LayoutModel+PaneClose.swift`) hides the pane from the shown
  screens (`overlaid`) and shows the close sizing it leaves (derived on every overlay, nothing held per split);
  it moves the model's focus to the `successor` (the first pane of the closed pane's sibling) when
  the closed pane had it. A pane with a sibling in its split tree, or a column's only pane while
  another column stays (its column goes with it, see Doubts), closes this way: the last pane of a
  screen and a pane in a column with rows leave with the daemon's tree, as before. The hold ends when a snapshot no longer holds the pane, or
  after `settlePaneClose` (the next snapshot wins); `cancelPaneClose` brings the pane back.
- **The last tab:** `PaneController.close(_:)` shows the pane close when its strip has no tab left
  (`PaneController+PaneClose.swift`), moves the window's focus to the successor when the pane had
  it, applies the layout in the same turn, and settles or cancels with the close's outcome.
  **Close Pane** (`closePane` verb) does the same around `close-pane`.
- `PaneMotionVariant.standard.closeSpring` is `split` (it was `exit`).
- `ScreenContentView.closing`: a departing structural change that springs holds the screen's
  terminals' grids until its panes land; `LayoutRootView.onTerminalGridHold` reports the first
  hold and the last release; the App holds `ResizeCoordinator.setHeld(_:by:)` with it, which keeps
  every pending grid (the newest wins) and sends each once when let go.
- `WindowCloseMotion`: `WindowController.windowShouldClose` starts the fade instead of closing
  (the close button, Close Window, `WindowTargeting.close`); `exit` spring on the window's alpha
  (critically damped: no flash back up; ~0.2 s to invisible, at speed fast); the next window
  takes the keys; `window.close()` runs when it ends; a second close ends it at once. A window
  the registry closes (`closeProgrammatically`: its workspace moved or ended) never fades, as its
  doc says (it would fight the receiving window for its surfaces). Not fullscreen, not minimized.

## Tests

`PaneCloseMotionTests` (fixed 120 Hz steps on a manual clock):

- the last tab's close moves every neighbour from the key's first frame and ends even, with no
  intent sent before the daemon's tree lost the pane;
- the daemon's echoes (the empty pane, then the tree without it) retarget nothing; the sizing
  intent goes once;
- a refused close brings the pane back with its sizes; a settled close yields to the next
  snapshot; the focus leaves the closed pane for its successor;
- a pane with no sibling leaves with the daemon's tree;
- the close runs on the split spring: a third of the way at 50 ms, monotone, no overshoot past
  0.25 pt, exact landing, at rest by 0.75 s, both axes;
- the close holds the grids from its first frame until its panes land; a held terminal resizes
  its PTY once, with its newest grid, when let go;
- Reduce Motion: one frame, no hold;
- a window fades from its first frame, monotone, takes no click, closes once at the end within
  0.35 s, and shows whole if it opens again; no fade under Reduce Motion.

## Doubts

- A column's only pane leaves with its column in the key's turn too (Leo 2026-10-25: "it's weird
  how closing the right pane seems be like... waiting for the right tab's closing animation to PLAY
  before closing...? we should never block shit on the tab animation"). It used to wait for the
  daemon's tree, so the emptied column showed its strip's tab close (`ui.animations.newTab`, on by
  default since) before it left. `LayoutModel.removingColumn(at:from:)` shows the columns as
  cmux-tui leaves them (`project_layout_columns`: a lone column is the screen's tree, a lone pinned
  dock stays; `normalize_dock_columns`). A close's sizes (even split ratios and fit-screen column
  widths) are derived, not held per split or column: the daemon's, then the sizes of closes that
  landed while another was pending, then each pending close in the order it was shown with the
  sizing it leaves. Overlapping closes, their echoes in any
  order and refusals each show what the pending closes leave; the sizes go out once, when the
  screen's last pending close resolves. A close's sizes supersede sent sizes the daemon has not
  acknowledged for the same splits and columns (an earlier close's flush). Every shown close, focused or not,
  takes its pane out of the focus coordinator's topology, so a later close never picks a hidden pane. When the closed pane had the focus, the focus reducer picks
  the successor from the held topology without the pane (`layout.closeFocus` and the window's
  history, close-focus.md), the pick the echo's topology would make; the window applies it in the
  key's turn.
- The window's fade is alpha only: AppKit gives no public way to scale a window, and its content
  cannot be snapshotted with its Metal and page layers.
- The grid hold is app-wide (every window's terminals) for the ~0.4 s of a close, not per pane.
- The focus goes to the successor before the daemon names its own: if the daemon picks another
  pane, the focus moves again on the echo.
- Not seen in the running app yet; the numbers come from the test clock.
