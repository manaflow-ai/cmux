# cmux NEXT: how we integrate Ghostty, and what is fundamentally wrong

Status: audit 2026-10-23 (PL-ghostty, perf lead batch 1). Lawrence: "surface and fix fundamentally
wrong things about how we integrate with ghostty in cmux-next"; resizing must be "as fluid as
possible". Targets are the perf lead's ([perf-lead.md](perf-lead.md) sec. 1): every action < 10 ms
p95 to its committed frame, motion at full refresh with 0 drops, light and STRESS sessions.

Code read at feat-cmux-next 62c427ab5bd, ghostty-next 5555f42. Paths: `app:` is
`Packages/macOS/CmuxNext/Sources/`, `gn:` is `ghostty-next/`, `tui:` is
`cmux-tui/crates/cmux-tui-core/src/`. Numbers marked "code" are counted from the code; numbers
marked "fleet" come from a fleet run (host, sha and refresh rate in sec. 5).

## 1. The integration today

One terminal is three processes and three VT parsers:

```
shell <-> PTY  [__terminal-host process]  parser #1 (full Terminal, 10 MB scrollback)
               | binary frames, Unix socket
               v
          [cmux-tui daemon]  surface mirror, parser #2 (full Terminal, 10 MB scrollback)
               | JSON lines, output as base64, one Unix socket per attached view
               v
          [cmux app]  TerminalSession (main actor) -> TerminalOutputLane (serial queue)
               -> ghostty_surface_process_output, parser #3 (GHOSTTY_SURFACE_IO_MANUAL_MIRROR)
               -> renderer thread -> Metal -> IOSurface -> IOSurfaceLayer.contents (main)
```

- Host parses every byte: `tui:terminal_host_runtime/shared/host_parser.rs:155`; it publishes raw
  bytes to subscribers before it parses (`host_start.rs:197-212`).
- Daemon parses every byte into its mirror (`tui:surface/hosted_reader/output.rs:41-42`,
  `Terminal::new(.., opts.scrollback, ..)` at `surface.rs:668`) and only then broadcasts to the
  app (`output.rs:83-90`, under the terminal lock).
- The app's surface parses again (`app:CmuxNextTerminal/TerminalOutputLane.swift:56-70`,
  mirror mode chosen in `TerminalSession.swift:142`: "the daemon's VT core answers DA/DSR").
- Daemon to app is JSON with base64 data: `tui:server/terminal_snapshot.rs:509-511`,
  `message_writer.rs:187-190`; decoded per line in
  `app:CmuxNextDaemon/Terminal/TerminalAttachment+Decoding.swift:153-155`.

Threads per terminal (code): host 7 + 2 per client; daemon 3 per surface + ~5 per attached view
connection; app 2 Ghostty threads per surface (`gn:src/Surface.zig:852-865`: renderer and termio
IO, the IO thread idles in manual mode), one output-lane queue, one transport reader. That is
~19 threads per terminal; fleet heavy run: 3,300 threads, daemon 797 at ~172 terminals
(speed-of-sound sec. 7).

## 2. Faults, ranked by what Lawrence feels

| # | Fault | Evidence | Real fix | Owner |
|---|---|---|---|---|
| G1 | **A resize frame shows the old text at the new size.** The surface is host-sized (`app:TerminalSurfaceView.swift` `createSurface`, `ghostty_surface_set_host_sized`). Each `set_size` marks the layer for display; Core Animation's display pass calls Ghostty's `displayCallback` → `drawFrame(true)` on the main thread (`gn:src/renderer/Metal.zig:237-241`), which draws the cells the renderer thread built for the *previous* grid (`generic.zig:1996-2140`: no `updateFrame` in that path) and blocks main until the GPU finishes. The reflowed text (reflow preview) comes later from the renderer thread as an async frame, and `setSurfaceCallback` discards an async frame whose size is no longer the host size (`metal/IOSurfaceLayer.zig:172-190`). In a continuous drag most async frames lose that race. | code; fleet frame counts in sec. 5 | **Size-synchronous frames**: `set_size` asks the surface's renderer thread for a frame at the new size with cells rebuilt (preview included) at once; the display pass waits for *that* frame (bounded) instead of drawing stale cells on main. N resizing surfaces then build in parallel on N renderer threads, main waits for the slowest, not the sum, and the CA transaction carries every terminal at its new size with its new text. | PL-ghostty (ghostty-next + `TerminalSurfaceView`) |
| G2 | **Every grid step of a resize is a full snapshot round trip and up to four whole-scrollback reflows.** App → daemon → host: host `term.resize` reflow #1 (`tui:host_shared/resize.rs:213`), PTY reads stall on `source_order_lock` meanwhile (`:121`); daemon mirror reflow #2 (`pty_surface.rs:580`) and a full render frame (`:632`); the daemon sends a READY snapshot, not an in-band resize (`attach_tap.rs:631-638`, `terminal_snapshot.rs:524`); the app's local-history restore decodes READY twice and reflows its own whole history, reflow #3 (`gn:src/termio/Termio.zig:1148-1310`, `old.resize(.., .reflow = true)` at 1242), **with `hold_frames = true` for the whole restore** (`:1200`, released at `:1213`): no frame draws, and the output lane is blocked, while it runs. 4 socket hops, ~7 thread handoffs per step (code); `ResizeCoordinator` allows one grid in flight (`app:CmuxNextBridge/ResizeCoordinator.swift:13-21`), so the step rate is bounded by this round trip. | code; fleet hold time per step in sec. 5 | App side: the mirror reflows itself at the owner's stream point (`set_grid` already runs in stream order on the lane) without holding frames: reflow off the live terminal, swap under the lock, draw the preview meanwhile. Wire: the resize is an in-band marker at its stream offset plus the 64-row history digest (`gn:src/terminal/history_digest.zig`), a snapshot only on mismatch. Daemon side: one reflow, not two (see G3). | PL-ghostty (app, ghostty-next); daemon/protocol half to PL-daemon |
| G3 | **Every byte is parsed three times, and the daemon's parse sits on the echo path.** Host parser, daemon mirror, app surface (sec. 1). The host publishes before it parses; the daemon parses first and broadcasts after, under the terminal lock (`tui:surface/hosted_reader/output.rs:30-90`). | code; STRESS has 10 printing terminals | Agreed with PL-daemon (pty-holder.md D2): the daemon forwards raw bytes before its parse (stream offset under the same lock); the per-terminal host goes away for one VT-free holder of every PTY fd, so the daemon's parser is the one authority outside the app and serves snapshots. 3 parsers become 2 (the app's is needed to draw). Wire: binary attach frames `\xFFCO` + kind u8 + len u32 + stream_offset u64 (kinds: output, grid marker with history digest, JSON event, snapshot READY, snapshot history), capability `attach-binary-output-v1`. | PL-daemon |
| G4 | **Terminal output goes through the main actor, chunk by chunk.** `TerminalSession` is `@MainActor`; its events task takes every `.output` on main (`app:CmuxNextTerminal/TerminalSession.swift:312-321`, `TypingLatencyProbe.mark(.outputMain)`), then queues it on the lane. 10 busy terminals in STRESS put one main-thread turn per output chunk on the same thread that runs motion frames and key dispatch; every echo waits behind them (bench-typing segment "decoded to main actor"). | code; fleet main wakes/s under output in sec. 5 | Output and in-stream grid/snapshot events go from the transport's decode thread straight to the surface's serial lane (it is already thread-safe and ordered); main sees only lifecycle and status events, coalesced to one turn per frame. | PL-ghostty (app) |
| G5 | **Output is base64 in JSON on one socket per view.** +33 % bytes, a base64 encode and a JSON serialize in the daemon (`terminal_snapshot.rs:327-329, 509-511`), a JSON parse and base64 decode in the app, per chunk. Coalescing only when the socket writer already holds 2 messages (`attach_tap.rs:643-660`). | code | Length-prefixed binary output frames on the attach stream (the host→daemon hop already is binary, `terminal_host_protocol.rs:730-735`). | PL-daemon (protocol), app decode PL-ghostty |
| G6 | **Each surface keeps two OS threads and per-surface GPU copies whatever it shows.** Renderer + IO thread per surface even in manual IO (`gn:src/Surface.zig:852-865`, `termio/Manual.zig:1-3`); 3 swap-chain frames each with its own IOSurface target and its own copy of both glyph atlases (`gn:src/renderer/generic.zig:456-484, 2142-2157`, `Metal.zig:37-38`), its own `MTLCommandQueue`. Occlusion does release the swap chain (`generic.zig:1311-1358`) and lowers QoS; every `process_output` still wakes the renderer thread of a hidden surface (`Termio.zig:1823`, early return at `Thread.zig:570`). | code; 172 terminals: 3,300 threads (speed-of-sound sec. 7) | Manual-IO surfaces run no IO thread (their timers move to the renderer loop); glyph atlases are one GPU texture per font grid shared by every surface; hidden surfaces wake nothing (renderer notified only while visible, a dirty flag otherwise). | PL-ghostty (ghostty-next), after G1/G2/G4 |
| G7 | **Idle terminals cost CPU.** 20 idle terminals 7.3 % CPU, 1 terminal 0.09 % (speed-of-sound sec. 5, Oct 20); baseline budget row `idle.terminals.app_cpu_pct` 1.3. Ghostty itself is idle when unfocused: the blink timer stops on focus loss (`gn:src/renderer/Thread.zig:351-364`) and the display link stops when nothing changes (`generic.zig:1422-1434, 2040-2044`). A focused, visible, non-blinking terminal still rebuilds and draws a frame every 600 ms (`cells_rebuilt` set on every rebuild, `generic.zig:3280`). | re-measure per process (app / daemon / hosts) in sec. 5 before any fix | Name the owner with a per-process sample first; then: no frame for a blink tick that changes no pixel. | PL-ghostty (Ghostty side), daemon side to PL-daemon |
| G8 | **Scrollback is held three times.** 10 MB limit in host, daemon mirror and app mirror (`tui:shared/codec.rs:676-678`, `surface.rs:177`, Ghostty default in the app). Fleet: 7.8 MB per hidden terminal (2.1-2.5 MB host process + 2.4 MB shell + app). | code + speed-of-sound sec. 5 | Falls out of G3 (no daemon mirror); app mirror keeps a bounded history and pages older rows from the host on scroll. | PL-daemon, then PL-ghostty |

Key to frame (shared with PL-typing): key on main → `io_write_cb` on main (`gn:src/termio/Manual.zig:108-130`,
the terminal lock taken 2-3 times on main for one key, `Surface.zig:3238-3264`) → writer task → JSON
`send-input` → daemon → host → PTY → shell → host PTY thread → host client writer → daemon frames thread
→ daemon surface thread (parse #2, G3) → attach-out thread (base64 JSON, G5) → line-out → app transport
thread → **main actor (G4)** → output lane (parse #3) → renderer thread (waits for a display-link tick when
the link already runs, `Thread.zig:574-588`) → Metal completion thread → `dispatch_async` main →
`layer.contents`. About 12 thread handoffs, 2 of them on the app's main thread.

## 3. Resize: what one frame costs today (code)

Per resizing terminal, per display frame of a divider drag or layout spring:

1. `setFrameSize` → `updateSurfaceSize` → `ghostty_surface_set_size` on main
   (`gn:src/apprt/embedded.zig:1128-1153` → `Surface.resize`; in mirror mode no reflow,
   `PageList.zig:1295-1300`), `ghostty_surface_size`, the reflow-preview toggle, and a grid report to
   `ResizeCoordinator` (held while a layout spring runs, `TerminalSurfaceView+PaneMotion.swift`).
   Side effect: `Terminal.resize` clears mode 2026 synchronized output on every call, even on a locked
   grid (`gn:src/terminal/Terminal.zig:4197`).
2. CA display pass: one synchronous `drawFrame(true)` on main with the previous cells, waiting for a
   free swap-chain frame and for the GPU (`generic.zig:2049`, `Frame.zig:122-126`), plus up to 3 new
   IOSurfaces per size (`generic.zig:2093-2103`).
3. Renderer thread: rebuild cells, build the reflow preview (bounded: screen + newest history,
   `gn:src/renderer/ReflowPreview.zig:125-305`), draw, present asynchronously; dropped if the size moved on.
4. Once per grid step (one in flight): the G2 round trip, ending in a READY restore that holds frames for
   a whole-history reflow.

So the text a person reads during a drag is one grid behind the edge at best, and freezes for the length
of a history reflow at each owner step. The fix order below targets exactly these: G1 makes step 2 draw
the right text on the frame the size changes; G2 removes the frame hold in step 4.

Seam with PL-motion-core (layout motion): their layer-driven motion resizes content once at landing
(F4). For live resize every frame (a divider drag, a window resize, and any spring they choose to keep
live) the terminal side offers: (a) `set_size` is cheap on main and returns at once; (b) the CA commit that
carries a pane's new frame carries that terminal's frame at the new size and with its reflowed text,
or the previous frame unchanged (never a frame with stale text at a new size, never a blank);
(c) a terminal whose pane only moves (no size change) does no work. The pane side calls nothing new:
`setFrameSize` stays the trigger.

## 4. Order

1. G1 size-synchronous frames (red: `bench-terminal-resize.py` stale-text frames and main ms per frame
   in a 2-terminal drag and a 12-pane column drag; ghostty-next commit pushed to the manaflow fork's
   main first, `docs/ghostty-fork.md`).
2. G2 app half: no frame hold during a local-history restore (red: frames held per grid step with
   50k lines of scrollback).
3. G4 output off the main actor (red: main-thread wakes per second and key-to-frame p95 with 10 printing
   terminals, `bench-typing.py`).
4. G7 measure idle per process, then fix the named owner.
5. G6 thread and atlas sharing.
G3, G5, G8 and the daemon half of G2 go to PL-daemon with these citations.

## 4b. Done so far (2026-10-23)

ghostty-next (PR 46, then one GhosttyNextKit pin bump), each with a red test commit first:
- G1 (UNVERIFIED, possibly a no-op; see "G1 evidence" below): a new host size draws at once on the
  renderer thread with rebuilt cells; the display pass presents that frame in its own CA commit
  (bounded 4 ms futex wait), never draws stale cells on main. This holds only if Core Animation runs
  the layer's display pass for a size change, which the before run did not show. G1 counts as done
  when bench-terminal-resize shows `host_display_passes > 0` and `host_fresh_presents > 0` at
  7d5fa1573 (or its successor) and a test fails when a resize frame shows cells of the previous size;
  no wait while frames are held; hidden surfaces draw nothing in a display pass. Counters
  `host_display_passes/main_draws/fresh_presents/late_presents`.
- G2 app half: a local-history restore holds frames only when a READY-only frame would show less.
- Mirror pixel-only resize: no `Terminal.resize`, mode 2026 survives a drag, `live_epoch` stays, the
  main thread never waits behind a parsed chunk.
- G6 part: a hidden surface's output does not wake its renderer per chunk. NOT PROVEN: its red commit
  (ghostty-next 7ec1bab, CI run 39975084450) fails only to compile (the test reads a field the fix adds).
  Next ghostty-next PR: a renderer-wakeup counter in its own commit, then a behavior test red on the
  pre-fix commit and green on the fix.
- G7 part: a blink tick of a hidden or steady cursor wakes nothing (agent TUIs hide the cursor).
- Key to frame: the first frame update of each refresh interval draws at once while the link runs.
- Bash integration: no fork per command on 5.3, none at start for PROMPT_COMMAND (PR 47, for
  PL-shell-integration).

cmux: G4 for live output only (output for a surface that already has content goes from the
off-main events loop straight to its lane, `TerminalOutputOffMainTests`), `bench-terminal-resize.py`,
`debug.terminal_display`.

Open after this batch:
- G1 evidence: the before run (light drag, d4a404a02ae, mac26 60 Hz) recorded 0 calls of
  `-[IOSurfaceLayer display]` on main, so in this path Core Animation may not run the layer's display
  pass and the stale-text frame comes from `contentsGravity` top-left over a held drawable, not from
  a main-thread draw. Decision: the present runs outside any display pass, from one main run-loop
  observer at order 1,999,999 (just before Core Animation's commit at 2,000,000) that the app
  installs only in a turn with a resized terminal (`TerminalHostFramePresenter`, through
  `ghostty_surface_present_host_frame`, ghostty-next PR 48). `setFrameSize` never waits: every
  surface sets its size during layout, so their renderers build in parallel, and each deadline is
  4 ms absolute from its own `set_size`, so a turn waits once, not N times.
  `TerminalResizeFrameTests` is the behavior test (the commit of a new size carries the frame at
  that size, and a reveal after a hidden resize does too).
- bash 5.3 `${ }` captures through 2 anonymous temp files in $TMPDIR per command (PS0 hook and the
  history read): cheaper than a fork, not zero (PL-shell-integration, perf-lead.md row 20).
- G4 rest: `.resize` (set_grid), snapshot restores (a local-history READY at every owner grid
  step), `.status` and `.sizedFor` still hop to the main actor, and the events loop waits for each
  hop; a READY also waits for `lane.drained()` inside that main-actor call. During a divider drag
  (main busy with motion) every output chunk behind a grid step waits for main. Target: queue grid
  locks and restores on the lane from the off-main loop (lane-side grid-lock generation) and send
  only model/UI updates (status, sizedFor, frame hold, counters) to main without waiting.
- G6 rest (one IO thread fewer per manual surface, shared atlas textures) and G7 per-process idle
  owner: not started.

## 4d. Cmd-D and Cmd-W resize the terminal's program at the start (2026-10-24)

Lawrence: "for cmd d and then cmd w, i think we need to trigger TUI resize much faster, even before
animation starts or finishes playing". Before, the layout held every terminal's grid from the first
split or close until the spring landed (`onTerminalGridHold` -> `ResizeCoordinator.setHeld`), so a TUI
redrew only after the animation and the daemon echo.

- Seam (PL-motion-core, `pl-motion-core-b11`): `PaneMotionTargeting.paneMotionWillRest(sizeChange:)
  -> PaneMotionAnchor`, called in the key's turn for each pane whose rest size changes, and again on a
  burst retarget; never per frame. The split/close grid hold is gone; the full screen hold stays.
- Terminal: the surface fits its final grid (`ghostty_surface_fit_grid`, ghostty-next PR 53: a
  shrinking pane does not have its final size yet, and Ghostty's padding math is not visible to
  Swift) and reports it at once (`TerminalGridPolicy.finalSized`). A daemon IO takes every grid on the
  main actor (`TerminalIO.resizeOnMain`), so a final grid never races an older grid still in the
  ordered input stream; `ResizeCoordinator.submitFinal` sends it in the caller's turn, and the
  one-in-flight echo rule keeps only the newest of a burst. The landing at the final grid reports
  nothing.
- Presentation: no frame reflows. A pane that grows has its content held at the rest size, so the
  surface is already final and its reflow preview reflows once until the owner announces the grid. A
  pane that shrinks keeps its larger view; once the owner announces the final grid the preview is off
  (`previewsViewGrid`), so Ghostty pads the final grid instead of reflowing it back to the wider frame.
- Anchor: a pane that grows downward pins its held content to the bottom when the cursor is in the
  lower half of a normal screen (the owner pulls scrollback down as rows grow, so the prompt is on the
  last row); a full-screen program (alternate screen) or a cursor near the top pins to the top.
- M6 (PL-burst): a window's full screen transition holds only its own terminals' grids
  (`Motion.isFullScreenTransitioning(_:)`); `ResizeCoordinator.shared` is removed, `AppServices`
  makes and injects the one coordinator.
- A3 (PL-script): a hidden or parked terminal's layout changes record the size only; showing it
  applies the last size once (no `ghostty_surface_set_size` and no PTY resize per hidden change). A
  terminal that is not shown reports no grid at all, its first forced report included; it reports
  when shown.
- A terminal that joins a pane already on a spring (a split's new pane gets its terminal from the
  daemon's echo about 75 ms in) asks the placement for its rest size change
  (`RestingPlacement.restContentSizeChange`) when it is shown and sends that final grid, once
  (review of pl-motion-core b14: before, 2 PTY resizes per Cmd-D for the new pane;
  `SplitTerminalResizeCountTests`).
- Tests: `TerminalPaneMotionFinalGridTests` (a real surface in a `LayoutRootView`: Cmd-D and Cmd-W,
  both axes, ask the IO for the final grid in the key's turn, once, nothing at the landing; a prompt
  on the last row rides the bottom of a pane that grows down), `TerminalHiddenResizeTests`,
  `ResizeCoordinatorFinalGridTests`, `TerminalGridPolicyHoldTests`. Bench:
  `bench-terminal-resize.py --layouts=split-resize,split-resize-stress` (`debug.terminal_final_grid`:
  key -> first and final grid sent, -> owner's final grid, -> first frame drawn at it).

## 4c. Review dispositions (batch 1, reviewers of both lead sessions)

Reviewers #1 and #2 (PR 46/47 at 7d5fa1573 and the cmux side), finding by finding:

| Finding | Disposition |
|---|---|
| `visible_hint` set only on the renderer thread: a reveal that resizes in the same turn presents nothing | Fixed: stored on main in `Surface.occlusionCallback` (ghostty-next 2c55ffb); cmux applies occlusion before size on a reveal (488e3b0b03c, red test in `TerminalResizeFrameTests`) |
| Busy terminal draws an early frame plus the tick frame each interval (2x GPU, 2x setSurface) | Fixed: an early draw only after a quiet interval (`last_tick_drew`, 2c55ffb); the interval state resets while the link is stopped (1f98b11) |
| `presentHostSized` blocks main up to 4 ms per pass; serial waits if moved to `setFrameSize` | Kept bounded and shared: one pre-commit present per turn, absolute deadlines from each `set_size` (PR 48); `setFrameSize` never waits. A hold or hide during the wait now wakes it (1f98b11) |
| `frames_held` read once before the futex loop; no wake on hold or hide | Fixed: re-read every wake; `setFramesHeld(true)` and a hide wake the waiter (1f98b11) |
| G1 unverified: the display pass ran 0 times | Accepted; present moved to the pre-commit observer (above), behavior test added; G1 counts as done only with the after bench (`host_present_calls` > 0, `host_fresh_presents` > 0) |
| Predicate-only tests (`drawsNow`, `blinkTickDraws`) | Accepted: `TerminalIdleCursorFrameTests` (render counters, visible-cursor control first) is red on GhosttyNextKit 5555f4220 (5 frame updates in 3 s at rest, hidden cursor) and green on 7d5fa1573 (0), aws minis; `TerminalResizeFrameTests` is red without the pre-commit present (each of 8 resize commits carried the previous size's frame, and the reveal too). The early-draw behavior through the thread is still open |
| Restore at the bottom: a scroll between the swaps shows the short READY history | Fixed: a scroll between the swaps holds frames until the result (2c55ffb, red bbe5965 fails in run 39969482574) |
| Restore at the bottom: the scrollbar thumb jumps to the short READY history at each grid step | Open: checked in the after bench; fix is to keep the old scrollbar total while the READY terminal draws |
| A -> B -> A: a late frame of the first A is presented for the second | Fixed: a size generation is checked at publish (1f98b11) |
| `publishFresh` locks, retains and wakes on every frame at rest; hidden keeps a frame | Fixed: publishes only while armed; a hide drops it (8ffdf01) |
| `drawn_since_tick` not reset when the link restarts | Fixed (1f98b11) |
| Mirror `pending_size` stale when the drag's last resize hits a busy lock and the terminal goes idle | Open, minor: a locked mirror's `Termio.size` feeds no drawn state (the renderer gets its size by mailbox); only a cell-size change during a parse with no later output stays stale |
| Events loop held the session strongly off main (leaked surface) | Dropped: `TerminalSessionReleaseTests` passed on the tree before the fix (scratch 9d25224797b, aws mini), so neither the bug nor the fix was shown; the change, its test and its test-only seams were reverted (lead: a fix needs a test that fails without it) |
| Release test polls with sleep/yield | Fixed: `TerminalOutputLane.queued(atLeast:)` and `ScriptedTerminalIO.streamEnded()` signals (a999f0d2ccd, 00ffc8fe13e) |
| bash funsub/`@a` change has no test or NEXT.md row | NEXT.md row added (8ffdf01); behavior test is PL-shell-integration's `fork_count_tests.rs` |
| ghostty-next red runs on PR heads, not main commits | Open: rerun on the main commits after PR 49 merges |
| ghostty-next CI test filter added | Removed (8ffdf01); tests run on the fleet by the agent (Lawrence 2026-10-23) |

G1 result (2026-10-23, aws-m4pro-9, 60 Hz, bench-terminal-resize light drag: 2 terminals with 20k lines,
240 moves): the pre-commit presenter (branch plghx-g1-full, `TerminalHostFramePresenter` +
`ghostty_surface_present_host_frame`) works: `TerminalResizeFrameTests` red without it (2f8b5a190ad: every
resize commit carried the previous size's frame; reveal after a hidden resize too) and green with it
(7f4133df957), and in the drag 136 / 106 fresh presents per round, 0 late, no display pass on main. It does
NOT land: frame pacing got worse. Before (scratch 4d4bc00456e) dropped 39 of 200 / 2 of 235 frames, main
p95 20.5 / 12.2 ms; after dropped 47 of 190 / 38 of 200, main p95 24.1 / 21.7 ms. The wait for the
renderer's frame (up to 4 ms from set_size, per turn) sits on the main thread every drag frame. Next: a
present that never waits on main (take the fresh frame if it is ready at the pre-commit observer, else keep
the last frame and let the async frame land), or the renderer rebuilding cells for the new size before the
layout pass ends; measured against these rows. Also open: the after run's idle-cursor phase drew 8 frames in
5 s at rest (before: 0); not explained yet.

Pending for the next batch (lead, from cmux-4f's review of pl-arch B3): after review-pl-arch-b3 lands,
`GhosttyRuntime+DefaultTheme.swift:78` calls `ColorTransition.current(for: themeScope.store)` instead of the
no-argument `ColorTransition.current`, which is then removed (PL-ghostty is its last caller).

## 5. Measurements

Filled in as fleet runs land: host, build sha, refresh rate, light and STRESS side by side.

| Date | Row | Host / sha / Hz | Light | STRESS | Note |
|---|---|---|---|---|---|
| | | | | | |
