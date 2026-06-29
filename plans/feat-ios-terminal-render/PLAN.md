# iOS terminal "blanks out" — durable plan

Worktree: `worktrees/task-ios-terminal-render-blank` (branch `task-ios-terminal-render-blank`, off main `261b950d5c`).
Status: analysis complete (rethink-architecturally + 3-advisor panel). No code written yet.

## Problem: two distinct bug classes behind "parts blank out"

1. **FREEZE / render stall** — a viewport or whole surface stops updating until you switch
   workspaces / background+foreground. Render-cadence bug, not content.
2. **DIVERGENCE** — specific rows go stale/blank and STAY wrong. Content bug from the
   iOS side accumulating synthesized VT deltas in a second emulator.

### Current pipeline (the root structure)
Mac ghostty grid → `render_grid_json` (`ghostty/src/apprt/embedded.zig:2330`) → structured
`MobileTerminalRenderGridFrame` on the wire (the migration that already shipped) → iOS
**re-synthesizes VT escape codes** (`MobileTerminalRenderGridReplay`, `…/CMUXMobileCore/Sources/CMUXMobileCore/MobileTerminalRenderGridReplay.swift:53-162`) →
feeds a SECOND libghostty via `ghostty_surface_process_output`
(`GhosttySurfaceView.swift:2170`) on a serial `outputQueue` that ALSO runs `render_now`.

- **Divergence root cause:** iOS grid is *accumulated* from synthesized deltas, not *set*
  from authoritative state. One missed `clearedRows`/changed-row desyncs it until a full
  snapshot. (`deltaPatchBytes` `Replay.swift:53-85`; producer diff `MobileTerminalRenderObserver.emitRenderGrid` `Sources/Mobile/MobileTerminalRenderObserver.swift:185-244`.)
- **Freeze root cause:** ingest (`process_output`) and GPU present (`render_now`) share one
  serial `outputQueue` (`GhosttySurfaceView.swift:642,2224,2725`); a stalled present blocks
  ingest. `renderInFlight` latch set on main (`:2723`) and cleared only in main completion
  (`:2733`); if present never completes, display-link ticks no-op and only
  `resumeRendering` on `didBecomeActive` (`:1105`) / a geometry redraw clears it — exactly
  why switching workspaces unfreezes it.

### Advisory panel conclusions
- A1 (ghostty internals): a hand-written `apply_render_grid` must re-derive wide-char tail
  cells (`embedded.zig:2071`) + grapheme clustering against an already-lossy JSON frame;
  hyperlinks/OSC8 are gone in the export. Strictly better mechanism may be shipping real
  page bytes via `Page.cloneBuf` (`ghostty/src/terminal/Page.zig:637`, offset-relocatable,
  used by `Screen.clone`/`PageList.clone`) — byte-exact, both ends pin same ghostty SHA
  (already true). Prefer reusing `Terminal.print` over raw cell writes.
- A2 (sync): A's WRITE model is right and kills the root cause. But "idempotent
  self-correcting" only holds for FULL frames; a clean delta on a correct base still
  converges to a wrong-but-stable grid if the Mac's dirty-tracking misses a row, and A ships
  no detection. Add a per-frame grid hash + auto-keyframe. For ~40×120, cheap bandwidth,
  always-full compressed snapshots may beat deltas. Reject raw-byte mirror (Option B):
  reintroduces sizing coupling + 256KB scrollback truncation.
- A3 (rendering): freeze is INDEPENDENT of A. Fix = split `render_now` off the ingest queue
  so a present stall can't block ingest, and make `renderInFlight` self-heal from the
  display link. Orthogonal; should land first.

## Optimistic scrolling — the invariant every change must respect
iOS holds a LOCAL scrollback mirror seeded by cold-attach replay (240 lines) + prefetch RPCs
(≤600, `Sources/TerminalController+MobileScrollPrefetch.swift`). Live deltas carry NO
scrollback. Local scroll = `ghostty_surface_mouse_scroll` immediately
(`GhosttySurfaceView+LocalScrollbackScroll.swift:11-22`). No per-frame jump-to-bottom
(`scroll_to_bottom` runs once, `:2284`).

> **Invariant: a live frame mutates only the active viewport — never scrollback, never the
> scroll offset. A repair/keyframe must be viewport-only and scroll-aware.**

Danger map:
- Queue-split freeze fix → safe; also move `mouse_scroll` onto the ingest queue for ordering.
- Grid-hash auto-keyframe via `ESC c` reset → YANKS a scrolled-up reader to bottom + wipes
  mirror. MUST be viewport-only + deferred while scrolled-up/mid-gesture.
- A viewport grid-apply → safe (viewport rows only).
- A′ page-clone on LIVE frames → resets offset every frame; DON'T. Snapshots/prefetch only.
- "Always full" via terminal reset → breaks scroll; redefine as viewport-full overwrite.

## In-flight PRs (do not collide)
- **#6543** "Fix iOS Ghostty render stall after resize/background" — ACTIVE (+616/-67, bumps
  ghostty). The freeze/cadence fix.
- **#6672** "Recover stale iOS Ghostty renders" — adds `TerminalRenderFlightState` + tests.
  = advisor A3's latch recovery.
- **#6647** "Preserve iOS terminal shell while reconnecting" — big (+3205), rewrites
  `TerminalOutputDelivery`/`MobileShellComposite`. Overlaps the divergence/delivery layer.
- **#5571, #6277** — old `Packages/CmuxMobileTerminal/...` path, `mergeable=false`.
  Superseded → close.

## Plan (phased; 0+1 fix the bugs, 2 makes the class impossible)

### Phase 0 — Land the freeze fix (no new code)
Dogfood + review #6543 then #6672; land in that order. Close #5571/#6277 as superseded.
While reviewing #6543: confirm scroll-offset mutations stay ordered with ingest if it
re-topologizes queues. Exit: resize/background/foreground freeze repros gone on device.

### Phase 1 — Make divergence self-healing (fork-free, highest leverage)
1. **Grid hash + auto-keyframe.** Mac stamps each frame with an xxhash over resulting cells;
   iOS hashes its grid post-apply and requests a full keyframe on mismatch. Closes "stale
   forever" regardless of producer losses. Base on `rowSignatures()`
   (`…/CMUXMobileCore/Sources/CMUXMobileCore/MobileTerminalRenderGrid.swift:238`).
2. **Scroll-aware viewport-only keyframe.** Repair clears+repaints the viewport only; never
   `ESC c`; defer/apply-off-screen while scrolled up.
Coordinate with #6647 (same files) — rebase on it or land first if it stalls.
Tests (two-commit red/green): dropped-`clearedRows` delta → hash mismatch → converges in one
frame; keyframe while scrolled up leaves offset + scrollback untouched.

### Phase 2 — Eliminate the round-trip (ghostty fork; gate on Phase 1 data)
Measure keyframe rate after Phase 1 = how lossy the producer really is. Only if it justifies:
- Libghostty WRITE path so iOS *sets* its viewport from the frame; delete
  `MobileTerminalRenderGridReplay`. Reuse `Terminal.print` for text (free wide+grapheme);
  prototype `Page.cloneBuf` page-bytes path in parallel.
- Scrollback unification: use page-clone ONLY on snapshot/prefetch/cold-attach → authoritative
  faithful scrollback, retire the lossy replay-flow. Live frames stay viewport-only (A).
- Constraints: live frames never touch scrollback/offset; A′ snapshots-only; pin same
  ghostty SHA. Exit: `render_grid_json`→apply→`render_grid_json` identity test; keyframe rate
  ~0; `Replay` deleted.

## Cross-cutting invariants
1. Live frame mutates only the active viewport.
2. Repair/keyframe is viewport-only + scroll-aware.
3. Convergence is detectable (grid hash), not assumed.
4. iOS scroll-offset mutations stay ordered with ingest.

## First action
Phase 0: dogfood #6543 + #6672 (tagged mac+iOS), drive to merge, close #5571/#6277.
In parallel spec Phase 1 grid-hash against `rowSignatures()`.
