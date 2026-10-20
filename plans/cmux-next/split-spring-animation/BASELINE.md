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

FRAMES_BEFORE

After the fix (same test, green commit):

FRAMES_AFTER

## Content and PTY

Every frame lays each moving pane out live at its spring rect (Lawrence 2026-10-18: "content
must move while it animates"), terminal included. The PTY gets a terminal's grid at most once
per echo of the one before (`ResizeCoordinator`, one grid in flight, newest wins), not every
frame.
