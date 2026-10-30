# Sidebar scroll lag (cmux-next)

Lawrence 2026-10-20: "I was just scrolling the sidebar and I encountered a ton of lag."

## First principles

A scroll should only move rows that are already laid out and draw the one or two rows that
come into view each frame. The cost of a frame should not depend on how many workspaces exist.

## Measurement

`SidebarScrollBench` (CmuxNextAppTests) builds a 260 x 900 pt sidebar over 10/100/500
workspaces shaped like a long-running window: a third in groups of eight, agent rows with a
status line, unread counts, working spinners, presence dots, branches and ages. It scrolls top
to bottom and back 40 pt per frame. Each frame moves the clip, then lays the window out,
displays it and commits (`CATransaction.flush`), and records main-thread CPU per phase.
Variants: pointer resting over the list (hover follows the scroll), three agent status ticks a
frame, and a move-to-top every 60 frames. `SidebarScrollProfile` samples the main thread (opt-in: `CMUX_SAMPLE_PROFILE=1`).

Before (fleet, feat-cmux-next ed7e0348206 + bench; two hosts):

| case (500 workspaces)          | aws-m4pro-7 p50 / p95 ms | cmux9s p50 / p95 ms |
|--------------------------------|--------------------------|---------------------|
| quiet scroll (100 workspaces)  | 3.4 / 8.1                | 1.1 / 2.9           |
| quiet scroll                   | 5.4 / 10.1               | 3.2 / 6.5           |
| pointer over the list          | 6.8 / 13.4               | 2.5 / 5.4           |
| + 3 status ticks a frame       | 7.9 / 18.7               | 3.3 / 8.5           |
| + a move-to-top every 60 frames| 9.4 / 24.5 (max 70)      | 5.1 / 13.7 (max 36) |

No frame made a new row view or laid the list out (0 reloads) in the plain scroll. The cost
still grew 100 -> 500 in every phase (scroll, layout, display, commit), so something per frame
walks more than the rows on screen.

## Causes, by measured cost

1. **Too many row views in the list (largest).** Overscan was 10 rows a side, a row parked
   only after another full overscan, and the pool kept up to 96 parked (hidden) row views in
   the list. At 900 pt that is about 170 row views of ~20 subviews each for ~22 visible rows.
   AppKit walks every one of them each scroll frame: the clip's bounds change marks tracking
   areas dirty recursively and the commit rebuilds them (`_NSTrackingAreaAKViewHelper`,
   ~165 of ~1,140 frame samples), the layout pass searches the subtree for views that need the
   layout engine (`_findAnySubviewNeedingAutoLayoutEngine`, ~115), and the commit collects
   layers (~40). At 100 workspaces the pool never filled, hence the growth with count.
   Fix: overscan 3 rows a side, park one row past the realization rect, a
   pool of two realization rects of rows (`SidebarRowViewPool.limit(forHeight:rowHeight:)`): a
   space switch parks the page it leaves and takes the other back.
2. **Status ticks while scrolling.** Each patched row is configured, laid out and redrawn
   (glyph images) in the frame: ~0.3 ms a row. Bounded by rows on screen; not changed here.
3. **Move-to-top while scrolling.** A notification that moves a workspace is a structural
   change: the whole list is laid out again (`SidebarLayout.make` over every row), 20-70 ms on
   a 500-row list. Next fix: a move patches the layout in place instead of a full reload
   (owned with the ordering work, a131).

Not causes (checked): no SwiftUI in the row path; no timers or per-frame timestamp updates in
rows (a194 hides times); spinners are layer animations; no shadows, blur or offscreen masks on
rows (the edge fade mask is one gradient layer set only when an edge flips); hover follows the
scroll without fades or marquees; no image decoding while scrolling (glyph images are cached
per text).

## Tests

- `SidebarScrollCostTests.aScrolledListHoldsAFewScreensOfRowViews`: after a scroll the list
  holds at most 2 x visible row views (before: 82 for 30 visible; after: 48). This is the
  test that fails before the fix on every host.
- `SidebarScrollCostTests.scrollingFiveHundredWorkspacesStaysInsideTheFrameBudget`: p95 frame
  under 8 ms at 500 workspaces (quiet, pointer over, ticking agents) and no list reload. On
  fast hosts the before build passes this too (p95 1.7 ms on aws-m4pro-6), so it is a budget
  guard, not the red test.

## After

Same bench, 500 workspaces, p50 / p95 ms (one run per build; hosts differ, so compare the
row-view count and the ratio, not hosts):

| case                           | before, aws-m4pro-6 | after, aws-m4pro-3 |
|--------------------------------|---------------------|--------------------|
| quiet scroll                   | 1.12 / 1.74         | 0.72 / 1.14        |
| pointer over the list          | 1.21 / 1.76         | 0.79 / 1.23        |
| + 3 status ticks a frame       | 1.19 / 1.59         | 1.00 / 1.66        |
| + a move-to-top every 60 frames| 1.41 / 2.11         | 1.17 / 1.91        |
| row views held (30 visible)    | 82                  | 48                 |

The remaining spikes (p99 ~15 ms) are the move-to-top full reloads (cause 3). The render also
stopped copying every workspace to check for provisional rows on each reload (71 of ~880 reload
samples).
