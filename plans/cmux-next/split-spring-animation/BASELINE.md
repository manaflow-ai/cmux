# Split animation before (feat-cmux-next dde0ebbee3a, 2026-10-19)

Lawrence 2026-10-19: "it looks like we add a new pane and then resize to rest". Design of the
fix: [DESIGN.md](DESIGN.md).

## What animated, in what order

Cmd-D on a pane of a row of two (p1 | p2, Cmd-D on p2), `layout.splitSizing` even (the
default), `ui.paneAnimations` on (the default), 120 Hz:

1. **Key's turn (frame 0).** `PaneHandlers.split` puts the provisional split in the store
   (`Intent.splitPane`, ratio 0.5) and lays it out (`applyCurrent`, a75's instant split). The
   view sees one structural change: p2 splits into p2 | p3 at 0.5. `PaneArrival` seeds p3 as a
   zero-width sliver on p2's right edge; p2 shrinks to a quarter of the row, p3 grows to a
   quarter. **p1 does not move**: the root split is still 0.5.
2. **Frames 1 to ~12.** All moving edges spring on `move` (response 0.15 s, critically damped):
   half the travel at 40 ms, 92% by 100 ms.
3. **~75 ms.** The daemon's echo of the split (pane-added, layout-changed) lands; the view keeps
   springing (`inFlight`), no visible change.
4. **~100 ms (daemon send to reply: 107-112 ms p50 on the owned mini, instant-new-surfaces.md).**
   The handler's task resumes after the reply and calls `applySplitSizing`: a ratio intent
   for the root (0.5 to 1/3). The view sees a non-structural ratio change and retargets every
   pane: **p1 starts shrinking from rest now**, p2 and p3 (almost at their quarter) turn around and
   grow to a third. This is the second motion the user sees.
5. **~100 to ~350 ms.** The second `move` spring runs to rest.

So two motions, ~100 ms apart, the second one reversing p2 and p3. The same happens for
Cmd-Shift-D in a column of two, for any split in a longer same-axis chain, and for the page
split (a browser tab, the New Tab page or a chat: `NewTabPage.split` applied the sizing in the
creation's completion). The first split of a lone pane has no sizing (0.5 is already even), so
it was one motion, on the fast `move` spring.

Close (Cmd-W on a pane): one motion already. The store applies the close and
`LayoutModel.applyCloseSizing` evens the chain inside the same `apply(screens:)`, so the view
gets one target, on the `exit` spring (0.24 s, critically damped).

## Frames (recorded)

`SplitSpringMotionTests.theRepliesSizingLandingMidSpringChangesNothingOnScreen` drives the real
`LayoutRootView` / `ScreenContentView` springs on a manual 120 Hz clock (window 1200 x 800),
with the reply's sizing at frame 12 (100 ms). Widths in points of p1, p2, p3 (the new pane), on
the red commit (the old behavior):

| frame | ms | p1 | p2 | p3 |
|---|---|---|---|---|
| 0 | 0 | 600.0 | 599.0 | 0.0 |
| 1 | 8 | 600.0 | 584.5 | 14.5 |
| 3 | 25 | 600.0 | 514.5 | 84.2 |
| 6 | 50 | 600.0 | 413.3 | 185.1 |
| 9 | 75 | 600.0 | 352.7 | 245.5 |
| 12 | 100 | 600.0 | 322.6 | 275.5 |
| 13 | 108 | 590.3 | 321.6 | 286.1 |
| 14 | 117 | 569.0 | 327.8 | 301.2 |
| 16 | 133 | 518.6 | 347.1 | 332.3 |
| 18 | 150 | 476.2 | 365.0 | 356.8 |
| 21 | 175 | 435.8 | 382.7 | 379.5 |
| 24 | 200 | 415.7 | 391.8 | 390.5 |
| 30 | 250 | 402.7 | 397.7 | 397.5 |
| 36 | 300 | 400.4 | 398.8 | 398.8 |
| 43 | 358 | 400.0 | 399.0 | 399.0 |

p1 stands still for 100 ms, then starts from rest; p2 shrinks to 322.6 and grows back to 399 (a reversal); rest at frame 43 (358 ms).

After the fix (same test, green commit):

| frame | ms | p1 | p2 | p3 |
|---|---|---|---|---|
| 0 | 0 | 600.0 | 599.0 | 0.0 |
| 1 | 8 | 596.9 | 595.9 | 6.2 |
| 3 | 25 | 577.8 | 576.8 | 44.3 |
| 6 | 50 | 536.6 | 535.6 | 126.4 |
| 9 | 75 | 496.7 | 495.7 | 206.1 |
| 12 | 100 | 464.7 | 463.7 | 270.0 |
| 13 | 108 | 456.0 | 455.0 | 287.3 |
| 14 | 117 | 448.3 | 447.3 | 302.7 |
| 16 | 133 | 435.4 | 434.4 | 328.3 |
| 18 | 150 | 425.6 | 424.6 | 347.9 |
| 21 | 175 | 415.4 | 414.4 | 368.4 |
| 24 | 200 | 408.9 | 407.9 | 381.2 |
| 30 | 250 | 402.7 | 401.7 | 393.6 |
| 36 | 300 | 400.7 | 399.7 | 397.6 |
| 46 | 383 | 400.0 | 399.0 | 399.0 |

Every pane moves from frame 1; p1 and p2 only shrink and p3 only grows (no reversal); the
reply at frame 12 changes no target; the three are at rest together by frame 46 (383 ms). Fleet run:
the green commit's `SplitSpringMotionTests` shard, 2026-10-20.

## Content and PTY

Every frame lays each moving pane out live at its spring rect (Lawrence 2026-10-18: "content
must move while it animates"), terminal included. The PTY gets a terminal's grid at most once
per echo of the one before (`ResizeCoordinator`, one grid in flight, newest wins), not every
frame.
