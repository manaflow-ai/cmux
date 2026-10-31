# Split spring: one motion for Cmd-D and Cmd-Shift-D

Lawrence 2026-10-19: "the animation for Cmd+D and Cmd+Shift+D can be more fluid. Right now it
looks like we add a new pane and then resize to rest but we can ideally resize all of them while
adding a new one. Think of how to do the best spring animation for this from first principles."

What happened before: [BASELINE.md](BASELINE.md). Tests:
`Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/SplitSpringMotionTests.swift`.

## Principles

1. **One gesture, one target.** A split with `layout.splitSizing` = even (the default) is two
   facts: a new leaf, and new ratios for every split of the same-axis chain. They are one
   gesture, so the window must learn both in the same layout pass. A spring can only look like one
   motion if its target is set once. Two targets ~100 ms apart (the split in the key's frame, the
   sizing after the daemon's reply) give two motions however good the spring is. This was the
   bug, not the curve.
2. **Interpolate the layout, not the pixels.** Every pane edge and divider is a linear function of
   the split fractions. The view keeps one spring per edge, all with the same parameters, all
   started together from rest (or from one shared velocity). The damped oscillator is linear,
   so each edge covers the same fraction of its travel at every instant: the frames are exactly
   the layout at an interpolated fraction. Nested splits stay consistent, the panes tile the
   container in every frame (sum of extents plus dividers = container), and all panes land in
   the same frame. The new pane starts as a zero-width (zero-height) sliver on the split edge
   (`PaneArrival`) and grows while its neighbours shrink.
3. **The key answers at once; the motion settles softly.** The eye reads "my key did something"
   from the first ~50 to 80 ms, and "it is done" from the last visible pixel. A spring with a
   longer response and a damping just under 1 gives both: a quick start, a short tail.
4. **No visible overshoot of content.** Panes are laid out live (Lawrence 2026-10-18: "content
   must move while it animates"), so an overshoot would grow a terminal past its final grid and
   back. The overshoot must stay under a device pixel on the largest split.
5. **Interruptible.** A second Cmd-D (or a close, or the daemon's echo) mid-motion retargets the
   springs: value and velocity carry over (`SpringValue` keeps both), nothing restarts from rest.
6. **Reduce Motion** (or `ui.paneAnimations` off, or speed off): the final layout in one frame.
7. **Optimistic, but exact.** The daemon still owns the ratios. The window shows the sizing as a
   local override in the key's turn and sends nothing; the reply sends the ratio intents under
   the same transaction (the echo confirms what shows; nothing moves); a refused split drops the
   override with the split.

## Spring

New token `split`: response 0.28 s, damping fraction 0.95, not structural (the bounce setting
does not change it). Values for a 700 pt travel (the new pane of a full-width split), 120 Hz:

| Spring | half travel | 95% | visible end (0.5 pt) | overshoot |
|---|---|---|---|---|
| `move` 0.15 / 1.0 (before) | 40 ms | 113 ms | 246 ms | 0 |
| `exit` 0.24 / 1.0 (close; a window close since close-animation) | 64 ms | 181 ms | 385 ms | 0 |
| `zoom` 0.30 / 1.0 | 80 ms | 227 ms | ~480 ms | 0 |
| **`split` 0.28 / 0.95** | **73 ms** | **195 ms** | **375 ms** | **< 0.1 pt** |
| 0.30 / 0.90 | 76 ms | 192 ms | 306 ms | 0.5 pt |
| 0.30 / 0.85 | 74 ms | 176 ms | 423 ms | 3 pt |

Why these:

- **Response 0.28 s.** Close to `zoom` (0.30) and `exit` (0.24), the other pane-layout motions,
  so splitting, closing and zooming feel like one family. Half the travel at ~73 ms: the key reads
  as answered within the first 5 frames. `move` (0.15) finished 92% of the travel before the
  reply's resize even started, which is what made the second phase stand out; at that pace a
  split also reads as a snap, not a motion.
- **Damping 0.95.** Critical damping (1.0) has the slowest possible tail for its response: 446 ms
  to the last visible pixel at 0.28. 0.95 cuts that to ~375 ms, and its one overshoot is
  e^(-ζπ/√(1-ζ²)) = 7e-5 of the travel: 0.05 pt on 700 pt, under half a pixel even at 2x (the
  frame snaps at 0.25 pt and 2 pt/s before that). 0.90 still overshoots 0.5 pt (one pixel at
  2x, a terminal column for a frame); 0.85 overshoots 3 pt, visible.
- **Not structural.** Structural springs are forced to damping ≥ 1 with bounce "none" and get
  0.15 bounce with "subtle"; both would undo the choice above. `zoom` and `exit` are not
  structural either.
- `ui.animationSpeed` normal scales it 1.5x like every token; Debug Settings can tune it live
  (`motion.spring.split`); the pane motion variant lab keeps its choices (`crisp`: `move`,
  `softLanding`: `settle`).

## Implementation

- `LayoutModel.showSplitSizing(_:)` (key's turn): holds the chain's even ratios as local,
  unsent overrides (`holdSplitRatio`), so the provisional split from the store and the sizing reach
  the view in the same `applyCurrent`. Returns a `PendingSplitSizing`.
- `commitSplitSizing(_:)` (after the reply): sends the ended ratio intents under the same
  transaction, only for splits no other gesture took over since. `cancelSplitSizing(_:)` (a
  refused split): `rejectTransaction`, back to the daemon's ratios.
- `PaneHandlers.split` (terminal Cmd-D / Cmd-Shift-D) and `NewTabPage.split` (the page split from
  a browser tab, the New Tab page or a chat) use it. The non-optimistic path (a daemon without
  client keys) and the layout-intent split (`WorkspaceContentController` `.split`) still size after
  the reply; see Doubts.
- `ScreenPaneMotionState.retarget(splitting:)`: a change with an arriving pane takes
  `PaneMotionVariant.splitSpring` (`split` by default); a close takes `split` too since close-animation (it was `exit`); anything else `move`.
  A change while a split still moves (the daemon's echo ~75 ms in) keeps the spring and velocity.
- One landing: a screen's pane and divider frames advance without settling one by one
  (`AnimatedFrame.advanceUnsettled`) and snap together once every edge is within a quarter point
  of rest. Before, each edge snapped on its own, so edges with shorter travels landed frames
  early and the gap beside them changed by up to 0.25 pt in the last frames.

## Content during the motion

The task asked to resize the PTY "once at rest or at most a few times" and show content clipped.
Lawrence decided the opposite on 2026-10-18 ("content must move while it animates": every pane
is laid out live at its spring rect, as a macOS live window resize is, and nothing holds a
final-size layout under a clip, so nothing jumps at rest). That decision stands for the views.

The PTY grid waits for the whole gesture (Lawrence 2026-10-20: "when I do Command-D multiple
times, the animation is not perfectly fluid"). Before this change, `ResizeCoordinator` sent a
terminal's grid about once per echo while the split sprang: a handful of grids per terminal per
split, and more on rapid Cmd-D. Each grid was a PTY reflow and a rebuilt daemon screen at a size
no frame rests at, so the text re-wrapped under the moving edges and the main thread took the
rebuilt screens mid-motion. Now a split holds the grids as a close does (close-animation:
`ScreenContentView.holdsGrids`, `ResizeCoordinator.setHeld`). The hold starts in the key's frame
and lasts until every pane landed, and a Cmd-D pressed during the motion keeps the same hold.
Each terminal then sends its newest grid once. Tests:
`aSplitHoldsTheTerminalGridsUntilItsChainLands` and `fiveRapidSplitsAreOneMotion`. Real window:
`scripts/measure/split-spring.sh`. Drags and live window resizes stay real time, at most one grid
per echo (`aSpringingTerminalResizesItsPTYAtMostOncePerEcho`).

## Tests

`SplitSpringMotionTests` (fixed 120 Hz steps on a manual clock):

- every pane of the chain moves from the key's first frame, and the chain ends even;
- the reply's sizing landing 12 frames in retargets nothing (the user's repro; it also prints the
  frame table used in BASELINE.md);
- the ratio intents go only after the split landed; a refused split takes its sizing back;
- the split spring: a third of the way at 50 ms, monotone, no overshoot past 0.25 pt, exact
  landing, at rest by 0.75 s, both axes;
- every frame tiles the row (left edge fixed, no hole at the right, every gap constant), all
  panes start in frame 1 and land together;
- a second split mid-motion keeps the first one's velocity, nothing jumps;
- Reduce Motion: final layout in one frame;
- cost: no frame of a 3x3 grid split over 16 ms; PTY resizes at most once per echo.

## Doubts

- `split` is Swift-only: cmux-motion's `MotionSpring` (Rust, `ALL` order = C ABI index) ends at
  `tabOpen`. Adding it there changes the app-ffi crates and needs a new FFI pin build; parity
  compares the tokens both ports have, so nothing breaks meanwhile.
- The non-optimistic split and the layout-intent split still show the sizing after the reply.
- Not seen in the running app yet; the numbers come from the view's own springs under a test
  clock, not from a screen recording.
