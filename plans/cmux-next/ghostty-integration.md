# cmux NEXT: Ghostty integration from first principles (parity with upstream Ghostty.app)

Status: DESIGN, approved by Lawrence 2026-11-10 (cmux-ad m91). This doc changes no code. Steps 1-4 have open PRs
(sec. 5.1 gives each PR, its state and where it differs from this design); nothing of the plan is merged and no
parity number is measured yet. Owner: GHOSTTY INTEGRATION (perf lead task, cmux-ad m86).

Order (Lawrence, cmux-ad m86): "from first principles we need to integrate with ghostty better" and
"scrolling is slow in ghostty as well".

Code read at cmux `origin/feat-cmux-next` 678886bd10d, ghostty-next pin `b3a5ebfdfe70` (still the pin at
`7d3e8472628`, 2026-11-10; `CmuxNextTerminal/` has no change between the two commits). Paths: `app:` is
`Packages/macOS/CmuxNext/Sources/`, `gn:` is the ghostty-next tree at the pin, `up:` is upstream
ghostty-org/ghostty at the pin's upstream base. The audit of 2026-10-23
([ghostty-integration-DESIGN.md](ghostty-integration-DESIGN.md), faults G1-G8) stays the record of the
transport faults (3 parsers, base64 JSON, main-actor hops); this doc is the target and the plan.

## 0. Facts first

| Fact | Value | How found |
|---|---|---|
| Upstream base of the current pin `b3a5ebfdfe70` | `c7f68a7f48c6` (upstream main, 2026-11-03, "macOS: fix tab bar frame on macOS 27", #15029) | `git merge-base b3a5ebfdfe70 upstream/main` |
| Upstream base of the earlier pin `8379ecc8a` | `c7f68a7f48c6` (the same) | `git merge-base 8379ecc8a upstream/main` |
| Upstream base of `538a3e2ef` (pin before #39026) | `c7f68a7f48c6` (the same) | same |
| Fork size | 294 non-merge commits, 350 with merges, `c7f68a7f48c6..b3a5ebfdfe70` | `git rev-list --no-merges --count` |
| Renderer and embedding diff vs base | 25 files, +6,754 / -152 lines in `src/renderer`, `src/apprt/embedded.zig`, `include/` | `git diff --stat` |
| Lawrence's standalone Ghostty.app | upstream 1.4.0, `83fb95624` (2026-10-27): an ancestor of the base, 148 upstream commits before it; only 2 of them touch `src/renderer`, `embedded.zig` or the macOS surface view (`0e067ded7` nullability in ghostty.h, `6573de67e` ArrayList rename): no render-path change | `git log 83fb95624..c7f68a7f48c6 -- ...` |
| Upstream needs Zig | 0.17.0 (`build.zig.zon` `minimum_zig_version`) | `git show c7f68a7f48c6:build.zig.zon` |

So "upstream Ghostty.app at the base" and Lawrence's 1.4.0 draw the same way. His feel on his own Mac (load
66-81 on 18 cores at 01:15Z) is not evidence; only a quiet fleet mini is.

## 1. Acceptance: parity with upstream Ghostty.app

**Rule.** A cmux terminal pane is accepted when, on one quiet fleet mini at 120 Hz, it is not worse than
upstream Ghostty.app built from the SAME upstream commit the ghostty-next pin is based on (today
`c7f68a7f48c6`), in every metric below. "Worse" means: past the upstream arm's own run spread AND past the
metric's floor. A pin change that makes any metric worse does not land.

**No CI.** This is not a CI gate, job, step or perf-gate row (CLAUDE.md, Lawrence 2026-10-23). The pin
author runs the bench on the fleet before the pin PR and pastes the parity table into the pin PR
description, with job IDs, host, macOS version and refresh rate. A pin PR without the table is not done.
Reviewers check the table, not a CI status.

### 1.1 Set-up (both arms, the same)

- Host: one fleet mini, not shared during the run (controller exclusive lease, `cmux-ci run --class exclusive
  --measurement`), never Lawrence's Mac. Before each arm: load average under 2 for 30 s, else the round is
  `not run`.
- Display: the lease's virtual display at 120 Hz, 2x (`--vdisplay 120x2`, the journeys rule: measured rate
  within 0.35 ms of 8.333 ms, else `not run`).
- Window: one window, one terminal, 160 x 48 cells, the same font (JetBrains Mono 13, the Ghostty default
  family), the same theme, `window-padding-x/y = 2`, no blur, no transparency, `cursor-style-blink = false`.
  One shared Ghostty config file is given to both apps (cmux reads Ghostty config through
  `GhosttyRuntime+ConfigFiles.swift`); a key both apps read differently is a bench bug, not a result.
- cmux arm: Release build with bench hooks (`cmux-ci build cmux --ref SHA --tag TAG --release --backend-mode
  local`, with a TAG that `release_bench_tags` in `scripts/cmux-next/cmux-next.dogfood.conf` matches), `CMUX_DEV_BACKEND_MODE=local`, the terminal in the first pane, sidebar at its default width.
  Its daemon and terminal host run as they ship (the bench measures the product, not the app alone).
- Upstream arm: Ghostty.app built on the fleet from the upstream base commit (`zig build
  -Doptimize=ReleaseFast` and the macOS app, Xcode Release), launched with the same config file, no other
  window. Never installed on any person's Mac.
- Input: real HID events from `scripts/journeys/hid_inject.swift` (CGEventPost at the HID tap at
  `mach_absolute_time` deadlines, events stamped on `CLOCK_UPTIME_RAW`). Neither app gets a socket call,
  a debug method or an injected `NSEvent` during a timed phase: the same input path for both.
- Frames: ScreenCaptureKit on the virtual display, a new stream of step 0: an `SCStreamOutput` at 120 Hz that reads
  each sample's `displayTime`, on the same clock as the HID log. (`scripts/cmux-next/media/record-window.swift` at
  the tip records one window to a movie at 60 frames per second at most and gives no time per frame.) A frame "shows X" when the pixel judge
  finds X in the terminal rectangle (a marker glyph row, see each journey).
- CPU: per process, `proc_pid_rusage` user+system time deltas read before and after the phase (no
  `sample`, no Instruments on a measured run). cmux arm: app, the `cmux-tui` daemon and the pane's
  terminal host, each and summed. Upstream arm: the Ghostty process.
- Order: ABAB, upstream first, 20 rounds per arm (n = 20 runs), each round a fresh launch. Each run gives
  its own p50/p95/p99/max; the arm's value is the median over its 20 runs, its spread is P90-P10 of the
  20 per-run values.

### 1.2 Metrics and journeys

| # | Metric | Journey (both apps) | Per run | n | Floor |
|---|---|---|---|---|---|
| S1 | Scroll, wheel, primary screen | `scroll-zsh` wheel bursts (sec. 1.3): zsh, 50k lines printed, 20 bursts of 120 wheel events at about 120 Hz, alternating up and down | per-frame interval p50/p95/p99/max while frames change; missed refreshes (an interval > 1.5 x 8.333 ms counts its extra refreshes); scroll input -> frame (probe 1) p50/p95/p99; renderer, main and io thread ms per frame (probe 2) | 20 runs x 20 bursts | 0.05 ms; 1 missed refresh per 1,000 |
| S2 | Scroll, trackpad, primary screen | `scroll-zsh` trackpad bursts: began, 118 changed, ended at about 120 Hz; the parity driver adds momentum events after `ended`, like a real fling | as S1, plus frames per burst and last event -> last changed frame | 20 runs x 20 bursts | as S1 |
| S3 | Scroll in `less` | `scroll-tui` less part: 50k-line file, wheel and trackpad bursts. Ghostty's alternate-scroll turns each event into an arrow key for the program: in cmux that key goes app -> daemon -> terminal host -> PTY -> less and the redraw comes back the same way, so S3 is a typing-path metric | as S1 | 20 runs x 24 bursts (12 wheel, 12 trackpad, the kit's `scroll-tui` counts) | as S1 |
| S4 | Scroll in `nvim` | `scroll-tui` nvim part (`nvim -u NONE`, `mouse=a`: mouse reports go to the program, the same path as S3) | as S1 | 20 runs x 24 bursts (12 wheel, 12 trackpad, the kit's `scroll-tui` counts) | as S1 |
| S5 | Output while scrolled | `scroll-zsh` streaming phases: output at the bottom, and output while scrolled up (the viewport must not move) | per-frame interval and missed refreshes, viewport drift (rows) | 20 | 0.05 ms; drift 0 |
| T1 | Typing, key -> frame | zsh prompt, 100 printable keys at random 80-200 ms gaps; idle, and with S5's output in a second split hidden behind (load) | HID stamp -> `displayTime` of the first frame that shows the glyph, p50/p95/p99/max | 20 x 100 | 0.05 ms |
| O1 | Output throughput | `cat` of a 100 MB file (`row NNNNNN` + 80 printable columns) then a marker line | Return key -> first frame that shows the marker; frames presented and missed refreshes meanwhile; CPU s per process | 20 | 1 % of upstream time |
| R1 | Resize frame time | window edge drag: 2 s, 120 Hz drag events, 160x48 -> 100x30 -> 160x48 cells, in zsh with S1's 50k lines, and with `nvim` full screen | per-frame interval p50/p95/p99/max, missed refreshes, frames whose text is at the wrong grid for its size (the judge reads the right margin column), last drag event -> first frame at the final grid | 20 x 2 | 0.05 ms; wrong-grid frames 0 more than upstream |
| I1 | Idle CPU | after S1's set-up, 60 s with no input, cursor not blinking, window visible and focused; then 60 s occluded | CPU % per process (and the cmux sum), idle wakeups/s (`proc_pid_rusage` `ri_interrupt_wkups`) | 20 | 0.1 % CPU; 1 wakeup/s |

Pass rule per metric and statistic (p50, p95, p99 and the miss count; max is reported, not judged):
`cmux_median <= upstream_median + max(upstream_spread, floor)`. A metric that one arm cannot measure (a
crash, a judge that reads nothing) is `not run`, never a pass. For I1 the cmux value is the SUM of app,
daemon and terminal host: Ghostty.app is one process.

The table that goes into a pin PR:

| Metric | stat | upstream (median, spread) | cmux old pin | cmux new pin | verdict |
|---|---|---|---|---|---|

### 1.3 One kit: the NIGHTLY REGRESSION scroll journeys

No second kit. The scroll journeys of NIGHTLY REGRESSION (m85) are the S journeys of this bench: branch
`nr/cmdt-latency-never-merge` at `40b6699592b` (never merge), `scripts/journeys/journeys/perf/scroll-zsh.json`
(50k lines, 20 wheel and 20 trackpad bursts of 120 events at about 120 Hz, output streaming at the bottom
and while scrolled up), `scroll-tui.json` (less, nvim/vim on a 50k-line file) and their `-big` variants
(60 workspaces), written by `scripts/journeys/gen-nightly-regression-journeys.py`. One round:
`/work/tmp/nightly-regression/tools/round.sh ARM BUILD_JOB JOURNEY HOST` (host-local on the perf lead's VM, not in the
repo, like `scroll_summary.py`; capture-host exclusive lease, no
mini scheduler). Summary: `/work/tmp/nightly-regression/tools/scroll_summary.py RUNS_DIR` (frame interval
p50/p95/max, missed 120 Hz refreshes, main ms per frame, Ghostty frames per second from
`render_counters`). The parity bench uses the same journey content, event counts and rates.

That kit measures cmux against cmux, through cmux's debug socket (`debug.frames`, synthesized scroll
events). Parity needs three parts that the kit does not have. They are REQUIRED parts of this bench:
without them the parity table is `not run`, never a pass.

1. **Scroll input -> frame latency probe.** No tool gives the time from a scroll event to the first frame
   that shows the moved rows. Design: the event is a real HID scroll (`hid_inject` gets a `scroll` step:
   line units for a wheel notch; pixel units with phases began/changed/ended and momentum for a trackpad;
   each event stamped on `CLOCK_UPTIME_RAW`, as its key and drag steps are). The frame is the
   ScreenCaptureKit frame of the virtual display with the first `displayTime` after the event at which the
   marker under the terminal's top-left cell (`row NNNNNN`, read by the journeys' text judge) moved by the
   expected rows. Latency = `displayTime - event stamp`, per event; p50/p95/p99/max per burst. The probe
   needs no app socket, so it reads both apps the same way.
2. **Renderer-thread time, measured directly.** The only proxy today is `render_counters` frames per
   second. Design: per-thread CPU time from `proc_pidinfo(PROC_PIDLISTTHREADS)` and `PROC_PIDTHREADINFO`
   (`pth_user_time + pth_system_time`, `pth_name`), read by a separate sampler process at the edges of each
   burst only (no `sample`, no stack walk while a burst is measured). Ghostty names its threads in both apps
   (`renderer` at `up:src/renderer/Thread.zig:207`, `io` at `up:src/termio/Thread.zig:243`); the main thread
   is the process's first thread. Per burst: renderer ms, main ms, io ms, and the rest of the process (the
   Metal completion thread is in it), each per frame shown. cmux also: daemon and terminal-host process ms.
3. **A driver for upstream Ghostty.app.** Ghostty.app has no debug socket. Design: the driver starts the
   app with the shared config and the journey's command (`Ghostty.app/Contents/MacOS/ghostty
   --config-file=X -e zsh -f -c '...'`; the command writes the 50k-line content itself), waits for a marker
   on screen (not a socket reply), moves the pointer over the terminal, posts the HID events of probe 1 and
   reads frames from the same ScreenCaptureKit stream. The cmux arm runs the SAME driver for the timed part
   (HID in, screen frames out). cmux's debug socket is used only for set-up and for counters read outside
   the timed span, so its `debug.frames` numbers stay cmux-only diagnostics.

These three parts go into `scripts/measure/ghostty-parity.sh` and its driver, beside the journeys kit
(step 0, sec. 5). They are bench tools, not CI: only the pin author runs them.

## 2. Ownership: who presents a terminal frame

**Target.** Ghostty owns its renderer thread, its layer and every present. cmux sets size, focus,
visibility and occlusion, and composites the layer in its view tree. cmux never draws a terminal frame,
never asks for one, never swaps the layer's contents and never holds a present. That is what upstream
Ghostty.app does: its `SurfaceView` calls `ghostty_surface_set_size`, `set_focus`, `set_occlusion`,
`set_content_scale` and the input calls, and nothing else on the frame path (sec. 2.1). The repo rule
(skills/cmux-debugging/SKILL.md): "Do not add a manual `ghostty_surface_draw` loop; rely on Ghostty wakeups and its
renderer to avoid typing lag."

### 2.1 Upstream Ghostty.app at the base (the reference)

- Size: `sizeDidChange` -> `ghostty_surface_set_size` (`up:macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:482-497`).
  The layer has `needsDisplayOnBoundsChange`; its display pass draws once on main (`up:src/renderer/Metal.zig:129,
  156-157`). Gravity is top-left, so old pixels are never stretched (`up:src/renderer/metal/IOSurfaceLayer.zig:34`).
- Every frame the renderer thread draws goes to the layer through `dispatch_async` to main, and a frame of the
  wrong size is dropped (`up:IOSurfaceLayer.zig:53-80, 104-118`). So in Ghostty.app too, a busy main thread delays
  every present.
- Pacing: the renderer's own CVDisplayLink in Zig (`up:src/renderer/DisplayLink.zig`). The app has no display link,
  no `ghostty_surface_draw` or `ghostty_surface_refresh` call, no frame hold, and touches `CATransaction` only for
  `contentsScale` (`SurfaceView_AppKit.swift:900-906`). On a reveal the renderer draws at once (`up:src/renderer/Thread.zig:316-321`).
- Input: `scrollWheel` -> `Ghostty.Surface.sendMouseScroll` -> `ghostty_surface_mouse_scroll` on main, the same in cmux
  (`app:CmuxNextTerminal/TerminalSurfaceView+Mouse.swift:98-116`). Scroll input is main-bound in BOTH apps: a busy
  main thread delays every scroll event before Ghostty sees it.

### 2.2 Every place where cmux presents, holds, draws or wakes a terminal frame

"Main" = the step runs on the app's main thread, so a busy main thread (for example the O(N^2) `@Observable` walk in
`AgentPaneLinkPlaces.follow`, #38166, found by NIGHTLY LOOP at 01:29Z and fixed by #40038) delays it. "Holds non-resize" = it can delay or
hide a present that does not follow a grid or size change (a scroll, output). Paths relative to `app:`; T/ is
`CmuxNextTerminal/`. Survey of 678886bd10d, line numbers checked.

| id | file:line | what | origin | Ghostty.app needs it? | main | holds non-resize | plan |
|---|---|---|---|---|---|---|---|
| P1 | T/TerminalFramePresenter.swift:43-382 | One presenter per window: a terminal's bounds change only in the commit that presents a frame drawn at them | e5ccc759105 #33956 (FRAME OWNER S4); switch deleted 76865dd55e5 #36478 | no (no host-frame API; display pass + wrong-size drop) | yes | via P2, P3, P5 | **move into Ghostty** (sec. 4) |
| P2 | T/TerminalFramePresenter.swift:258-334 (`armPass`, order 1,999,999 at :50; `pass`) | Run-loop observer before CA's commit: asks `ghostty_surface_host_frame`, presents under `CATransaction.lock()` (:306-312), groups the requests of one refresh | #33956 | no | yes | yes, small: a reveal or scale request (no size change) waits up to `groupTicks` = 2 refreshes if another request of its refresh is not ready (:45, :278-300) | move into Ghostty |
| P3 | T/TerminalFramePresenter.swift:220-256 (`tick`) | Each display tick: `ghostty_surface_host_frame_committed` for the last pass's commits (:222-225); presents READY / READY_PROGRAM of watched views under the lock (:242-248) | #33956; READY_PROGRAM case 67479c6b6cb #38206 | no | yes | **yes**: in EMBEDDER mode every frame, echo and scroll included, goes through main from the mode's start and after each main-thread size change until `committed` (`gn:include/ghostty.h` `GHOSTTY_HOST_PRESENT_EMBEDDER`). A watch that sees no SHOWN for more than `watchLimit` = 240 ticks is dropped (:52, :249-252), and then `committed` may not come until the next size change: that surface's frames can stay main-routed. Read only, not run: step 1 tests it | move into Ghostty; until then fix forward (step 1) |
| P4 | T/TerminalFramePresenter.swift:60, :103-108, :293-296 | #38206 READY_PROGRAM hold: old bounds and frame kept while the frame is READY (size only), at most `resizeHoldTicks` = 3 refreshes from the grid's send | 67479c6b6cb #38206 (RESIZE P0 12) | no | yes | **no**: needs `holdTicks > 0` (:104), set only by `place` / `requestWantedFrame` through `programHoldTicks` (T/TerminalSurfaceView+FrameOwner.swift:132-136: key resize or drag, alternate screen only); `requestPresentIfNeeded` passes 0 (FrameOwner:299). Output during a hold shows at the new size only when the hold ends | move into Ghostty's renderer (sec. 4) |
| P5 | T/TerminalSurfaceView+FrameOwner.swift:293-303 | `requestPresentIfNeeded`: on a show (TerminalSurfaceView.swift:323) or a backing change (:386), a presenter request when READY, READY_PROGRAM, PENDING or HELD | #33956 | no | yes | yes: a reveal with no size change waits for the next pass, up to 2 refreshes with a group wait (P2); HELD (mode 2026) keeps it pending | move into Ghostty |
| P6 | T/TerminalSurfaceView+FrameOwner.swift:325-330, called at TerminalSurfaceView.swift:232 | `ghostty_surface_set_host_present(EMBEDDER)` for the surface's whole life | #33956; no switch since #36478 | no (API absent) | set-up | yes: the mode is the cause of P3's main routing | replace by the synced renderer mode (sec. 4) |
| P7 | FrameOwner:248-254 | wrappers `ghostty_surface_host_frame`, `..._host_frame_committed` | #33956 | no | yes | see P3 | delete with P1 |
| P8 | FrameOwner:50-114, :233-244 (`layer.frame` under the lock :242), :341-345 | Old bounds kept on the anchor edge while a size is in flight; frame and layer frame set in the present commit | #33956 | no (bounds follow the view, gravity top-left) | yes | no | move into Ghostty (it owns its layer's bounds; cmux keeps the anchor) |
| P9 | FrameOwner:176-201; TerminalFramePresenter.swift:179-183, :343-358; T/TerminalHostView+PaneMotion.swift:60-75; CmuxNextDesign/PaneContentAreaView.swift:111-128 | Draw-ahead: the spring's next size (and grid) goes to Ghostty after this turn's pass | 76865dd55e5 #36478 (m26); `drawAheadOfFollow` f801ff735f5 #37108 | no (no springs) | yes | no | **keep** as a size input (a size is embedding); its presenter part goes with P1 |
| P10 | FrameOwner:153-164; T/TerminalHostView+PaneMotion.swift:90-101; CmuxNextLayout/Views/ScreenContentView+SnapFrame.swift:52-76; CmuxNextLayout/Views/LayoutFrameInput.swift:53 | Reduce Motion key snap waits up to 4 refreshes for the program, chrome and divider included | 67479c6b6cb #38206; SnapFrame 7216215175a1 #37330 | no | yes | no (key snaps only), but it delays chrome too, against the presenter's own rule (:40) | delete when P4 is in Ghostty |
| P11 | T/TerminalScreenSwitchWatch.swift:8-67; T/TerminalOutputLane.swift:37-44, :218-229 | Scans each output chunk for a DEC private mode introducer (ESC [ ?) or RIS (ESC c); only then the lane reads Ghostty's `alternate_screen` (`grid_metrics`) into an atomic flag that main reads without a lock | #38206 | no | no (lane) | no | delete: Ghostty knows its screen |
| P12 | FrameOwner:276-288, :334-338 | Display-scale hold: old `contentsScale` until the frame at the new scale | #33956 | partly (sets the scale at once) | yes | no | move into Ghostty |
| P13 | T/TerminalSurfaceView.swift:418-426 | `CATransaction` with disabled actions for `contentsScale` | cd5947da1572 #15511 | **yes** (`SurfaceView_AppKit.swift:900-906`) | yes | no | keep |
| P14 | T/TerminalSurfaceView.swift:230 | `ghostty_surface_set_host_sized(true)`: the drawable follows `set_size`, not the bounds | 177442c3066b (cx-8w027.8) | no | set-up | no | keep (embedding: cmux sets the size) |
| P15 | T/TerminalSurfaceView.swift:395-401, :579-584 | `setFrameSize` -> `ghostty_surface_set_size` (same-size calls skipped) | #15511 | yes | yes | no | keep |
| P16 | T/TerminalSurfaceView.swift:469-477 | `ghostty_surface_set_reflow_preview`: a reflowed picture until the PTY owner announces the grid | aec6712869f7 (cx-8w027.13) | no (Ghostty.app owns the PTY) | yes | no | keep (embedding: the daemon owns the PTY); the logic is in Ghostty already |
| P17 | T/TerminalSurfaceView.swift:650-680 (`ghostty_surface_refresh` :673) | A forced frame at each reveal (an OSC 11 parsed before the view was in a window) | b05fa01378c9 #24816 | no: the renderer draws on visible (`up:Thread.zig:316-321`) | yes (call) | no | delete after a fleet check of the #22282 repro; if needed, fix in Ghostty's visible path |
| P18 | T/TerminalFrameHold.swift:67-146 (`ghostty_surface_refresh` :119), HeldFrameView :150-185 | Replay and last-frame overlay: the old IOSurface or a CGImage in a view over a fresh surface until a frame drawn after the parse shows (2 ticks; at most 500 ms, :22; no limit before content is queued, :82-94) | 1dea4b48800b #20132 (cx-6so.23) | no (never swaps a surface) | yes | **yes**: it hides a fresh surface's output frames for up to 500 ms after its content is queued, and without a limit before that | move into Ghostty: an in-place reset/restore keeps the renderer's last frame; then delete (step 5) |
| P19 | T/TerminalLaunchFrames.swift:271-308, :576-585; T/TerminalLaunchFrame.swift:17-21 | Last-quit picture (JPEG, or PNG with clear pixels) over a pane before its surface exists, handed to P18 | 4e1c2efff996 #22842 | no | yes | through P18 | keep (app-level picture, not Ghostty's layer) |
| P20 | T/TerminalLaunchFrameKeeper.swift (`save` :177) | GPU copy of the presented frame to disk | 6cda7aede5da #31967 | no | start on main; render, encode and write off main | no | keep |
| P21 | T/TerminalLastFrame.swift, T/TerminalLastFrames.swift, T/TerminalFramePurgeability.swift:7-25; T/TerminalSurfaceView.swift:686-713 (`layer.contents = nil` :697, :710) | Keeps a hidden terminal's IOSurface (volatile), clears `layer.contents` when purged | 870490f20858 (cx-8w027.19.1) | no | yes | no (clears only) | move the purgeable marking into Ghostty's occluded path; keep the eviction policy |
| P22 | T/TerminalSnapshot.swift:11-24 | Reads `layer.contents` for hover previews | #15511 | no | yes | no | keep (reads) |
| P23 | T/TypingFrameProbe.swift:22-55 | Adds a `setContents:` override (`class_addMethod`) to Ghostty's layer class to mark presents (typing probe, echo prediction retire) | 66363aa2b065 #17494 | no | both (each present's thread) | no (one call per frame) | replace with Ghostty's present callback (sec. 4) |
| P24 | CmuxNextWakeups/FrameScheduler.swift:298-308 | The app's CADisplayLink per window; ticks P3, P18, P26 | not traced | no (Ghostty paces itself) | yes | through P3 | keep for app motion; its terminal clients go with P1 and P18 |
| P25 | T/TerminalHostView.swift:130, :430-454; T/TerminalHostView+PaneMotion.swift:35-40, :111-113 | Picks the size a surface gets in split, close and zoom springs; follows the pane in key resizes | d9b3e832d5be; a08c406ba0f9 #34170 | no (no springs) | yes | no | keep (embedding: size only) |
| P26 | T/TerminalPaneFollow.swift:135-225 | `debug.terminal_display` probe after each commit | 891a06d07f54 #36109 | no | yes | no | keep (debug) or delete with P1 |
| P27 | T/TerminalBlankWatch.swift:8-35 | Logs a pane still blank 500 ms after a reveal | e731c4009b46 | no | yes | no | keep (diagnostic) |

Not called by the macOS app: `ghostty_surface_draw`, `ghostty_surface_present_host_frame(_ready)`, `CVDisplayLink`.
Inputs and queries that present nothing: `fit_grid`, `drawn_grid`, `render_counters`, `size`, `grid_metrics`,
`set_grid`, `set_color_transition`, `set_content_scale`, `set_display_id`.

Ghostty-side present paths at the pin (for the "main" question):

| path | where | main |
|---|---|---|
| renderer frame -> `setSurface` -> `dispatch_async` main | `gn:src/renderer/metal/IOSurfaceLayer.zig` `setSurface` (upstream's only path) | yes |
| same-size frame -> `setSurfaceOffMain`, own CA transaction on the GPU completion thread | `gn:IOSurfaceLayer.zig:247-280` (fork #71, #79/#80) | no; falls back to main when the shown size differs or `mainPending` (P3) |
| display pass `drawFrame(true)` (first frame, `ghostty_surface_draw`) | `gn:src/renderer/Metal.zig` `displayCallback` | yes, waits for a free frame and the GPU |
| embedder present `ghostty_surface_host_frame(present: true)` | P2, P3 | yes |

Answer to m85 (a): the #38206 hold (P4) cannot hold a present that is not after a grid change. The presents outside a
grid change that cmux can delay are P3 (frames routed through main until `committed`), P5/P2 (a reveal, up to 2
refreshes) and P18 (a fresh surface's output hidden up to 500 ms). For scroll, the main thread is on the path in both
apps for input; in cmux it is also on the present path whenever P3 routes frames through main.

Target set: cmux keeps P9 (as a size input), P13-P16, P19, P20, P22, P25 and the diagnostics P26-P27. P1-P8, P10-P12,
P17, P18, P21's purgeable marking and P23 go into Ghostty or are deleted. P24 stays only for app motion (no terminal
client on a shipped frame path after P3 and P18 go; the debug probes P26 and `TerminalFinalGridTrace` stay, and the
grid-report coalescer's refresh tick, `TerminalFramePresenter.swift:384-391`, moves to another owner), so cmux keeps no
display link that paces terminal frames and no draw loop for a terminal.

## 3. The fork

Survey: `git log c7f68a7f48c6..b3a5ebfdfe70` in a clone of manaflow-ai/ghostty-next with upstream fetched; the fork's
own table is `gn:next/NEXT.md`. `git cherry -v upstream/main b3a5ebfdfe70 c7f68a7f48c6` marks all 294 commits `+`
(none is patch-identical upstream, the two picks included: they are squashed). Upstream main tip `c3b594ad2`
(2026-11-09) is 181 commits past the base and has nothing new on the renderer or present path.

Classes: **E** embedding API or behaviour cmux needs; **U** could go upstream as it is; **D** duplicates or
diverges from upstream; **C** cmux build/CI; **R** changes renderer or present timing (also for plain surfaces where
marked). Plans: **API** keep, reshaped into an embedding API upstream could accept; **UP** send upstream, then drop
at the sync that brings it; **DROP** delete at the next sync; **BUILD** move to cmux's build scripts (not source).

| # | Group (fork PR) | Key commits | What | Class | Plan |
|---|---|---|---|---|---|
| F1 | Apple build, CI, smoke (no PR, 18) | 82b67aca7 .. de340638c | iOS slices, xcframework target, GhosttyNextKit module name, flavors, render smoke; upstream workflows deleted | C | BUILD |
| F2 | Manual / mirror IO (no PR, 12) | 117c73bbb .. 31627e4b9 | MANUAL and MANUAL_MIRROR backends without a PTY; `ghostty_surface_process_output`, `io_write_cb`, `text_input`; manual surfaces do not redraw the prompt, keep raw OSC 7 | E (+D defaults) | API: the core of embedding a remote PTY. Upstream has libghostty-vt; propose "external IO" as the embedding surface. Defaults become explicit options |
| F3 | libghostty-vt replay APIs (no PR, 13; #45) | 0fb08ba18 .. 839e702fe | VT replay formatter fixes, cursor data, bounded Kitty state (cmux-tui) | E (formatter U; f9e99c83f, cfa4b3d22 D) | UP the formatter fixes; API the rest. Conflict risk: upstream's lib-vt ABI freeze after the base (657e82d1a, 796f09a6f, 12206bfb8, 0b7f9c156; fdedebade then makes upstream CI fail on an ABI change that is not an addition) |
| F4 | iOS renderer and mailbox (no PR, 6) | 9b466c7a5 .. 122010769 | iOS layer sizing, 72 DPI, layer detach; renderer mailbox never blocks; GPU completion never waits on the app mailbox; bounded wait in `setVisible(false)` | E+R (all surfaces) | UP mailbox, completion and bounded-wait fixes; API the iOS part |
| F5 | set_grid, snapshots (no PR, 9) | 559d886cf .. a9efcd613 | `set_grid`, `restore_snapshot`, `encode_snapshot`, `snapshot_version` (on upstream's snapshot module) | E | API |
| F6 | Prompt narrowing (no PR, 4) | 06675f816 43ffe4171 493a8871b 5555f4220 | Narrowed multi-line prompt redraws; `SHELL_REDRAWS_PROMPT`; zsh/fish `redraw=1` | U (5555f4220 D) | UP 43ffe4171; the zsh/fish default is a divergence: decide with upstream |
| F7 | bash integration (no PR, 2) | 72578da21 0493ce89a | No fork per command | U | UP |
| F8 | Host-size present pipeline (no PR, 17) | a85741a77 .. 538a3e2ef | `present_host_frame(_ready)`, `render_counters`; fresh-frame publish/take/drop; off-main present of same-size frames from the GPU completion thread; frames held during restores | E+R | replace by the synced renderer mode (sec. 4); keep `render_counters` as API; UP the off-main present of same-size frames (it helps Ghostty.app too: upstream sends every frame through main) |
| F9 | Wake reduction (no PR, 4) | 7ec1bab10 4988d8671 38fa79fbe f27680ed1 | Hidden output does not wake the renderer per chunk; a blink tick of a hidden/steady cursor wakes nothing; first update of a refresh interval draws at once | R (all surfaces) | UP 7ec1bab10, 38fa79fbe; f27680ed1 changes pacing vs Ghostty.app: keep only if the parity bench shows T1 better and S1-S2 not worse, else DROP |
| F10 | Mirror pixel-only resize (no PR, 2) | a8c5c7f8c 208e162d3 | A locked-grid mirror's resize never waits on the terminal lock | E | API (part of F2) |
| F11 | Wheel scroll off main (no PR, 4) | 65c9e1410 7badf825e 856edfe64 f3de4f477 | `scrollCallback` tryLocks; a plain viewport scroll under a busy lock goes to the IO thread (`.scroll_wheel`) | U+R (all surfaces) | UP (a scroll during heavy output in Ghostty.app has the same wait); S5 must show it is not worse |
| F12 | fit_grid (no PR, 2) | 8bbd6d386 ef6ce279a | `ghostty_surface_fit_grid` | E | API |
| F13 | Kitty port (1) | 723c4ab93 | Port of upstream #14811/#14812, both already in the base | D | DROP |
| F14 | iOS vsync (1) | 9ce9b7d08 | CADisplayLink paces iOS draws (`IosDisplayLink.zig`) | E+R | UP (upstream has no iOS app pacing) or API |
| F15 | RESIZE P0 12-16 (11) | 8c1eec2eb .. 7a372c740 | `Terminal.ProgramRedraw`: a host frame says whether the program drew a whole picture at the new grid (READY_PROGRAM) | E+R | keep the detector, move the hold into the renderer (sec. 4); UP as a resize-sync option |
| F16 | #13 sync docs | ca78a0b74 | NEXT.md | C | BUILD |
| F17 | #14 Mac embedder APIs | c7958cf4d .. f0501ab7f | `config_load_string`, padding c_get, font-size action callback, `grid_metrics`, bounded copy, `clear_selection` | E | API; UP `config_load_string` |
| F18 | #15 copy-mode selection | 6ebbc3cae 75afbb874 23652460f | `select_viewport_cell`, `selection_end`, `select_lines` | E | API |
| F19 | #16, #17 universal lib, prefix | b9bebd394; 9490c3e7f 7269f4ac2 | Universal macOS slice, archive name | C | BUILD |
| F20 | #18 OSC 133 prompt own line | 1db18667c .. 375278d10 | A prompt after a padded partial line starts its own line | U | UP |
| F21 | #19 iOS keycode HID usage | 6833c3bd6 579267a09 | iOS keycode = USB HID usage | E | API (maybe UP) |
| F22 | #20 restore local policy | d45eeb5e7 .. 22a4431bf | A restore takes the surface's colors and cursor defaults | E | API |
| F23 | #21 config introspection | 9b76c88e6 359dc1d83 | `config_key_count/name/source`, loaded files | E | UP |
| F24 | #22 deferred clipboard read | 245094cdc .. 2c79d5681 | Deferred OSC 52 reads | E | UP |
| F25 | #23 restore local history | aace61339 .. 8c90ceb7c | `restore_snapshot_local_history`, `history_digest` | E | API |
| F26 | #24 kitty image replay | a738d5d54 .. 141487ab0 | `kitty_replay_encode`, `apply_kitty_replay` | E | API |
| F27 | #25 mirror deps | 7416ba07d | Deps from a release mirror; unused since the v1.4.0 merge | C | DROP |
| F28 | #26 kitty local carry | 40c4f4c59 .. cce148643 | Texture reuse (89e62c7ef); `hold_frames` across the two restore swaps (cce148643) | E+R | UP 89e62c7ef; `hold_frames` goes with the in-place restore (P18, step 5) |
| F29 | #27 apple no i18n | 8999acace .. c29b13bd0 | No libintl on Apple slices | C | BUILD (maybe UP) |
| F30 | #28 draw idle frame now | 1fb7d17a7 | First frame after idle draws without waiting for vsync | R (all surfaces) | UP if T1 parity shows the gain, else DROP |
| F31 | #29 OSC 7501 | 45a5bff70 c98717f42 953e1414e | Dropped at the v1.4.0 merge; upstream bae2c3cdb in the base | D | DROP (already gone in content) |
| F32 | #31 libSystem override | 3f61be6eb .. 1108a8d9f | compiler-rt symbol override on non-Darwin hosts | C | BUILD |
| F33 | #32 Pst terminfo | 8754b730a 97f843dd9 | Pst capability | U | UP |
| F34 | #33 link filter | 25e0d94b2 c2a6690fb | `set_link_filter` | E (+R in updateFrame) | API |
| F35 | #34 terminal color c_get | af67bf802 e9f7d5a31 | c_get of a plain TerminalColor | U | UP |
| F36 | #35 min contrast glass | bcb2ac02d | Minimum contrast against the glass background | R (all surfaces) | UP (same bug in Ghostty.app) |
| F37 | #36 min contrast transparent | 56a8d83b6 6ce967166 | At opacity 0, contrast vs the configured background | R+D (all surfaces) | keep as a documented divergence, or an option UP |
| F38 | #38 host-sized drawable | 1a683dfbd 506d3e645 | `set_host_sized` | E+R | API (P14) |
| F39 | #39, #84 reflow preview | c65d8511a .. f9048ee65 | `set_reflow_preview`, `drawn_grid`; re-wrap off the terminal lock | E+R | API (P16) |
| F40 | #40, #41 palette blend, no rebuild | 67edc86eb .. b289682d1 | Cells hold color refs, theme colors blend on the GPU; a color-only change rebuilds no cells; `set_color_transition` | E+R (all surfaces: new per-cell work in `rebuildRow`, extra animation frames) | keep; the S1-S5 parity rows decide whether its per-row cost is visible in scroll (a scroll rebuilds rows) |
| F41 | #42 keep presented frame | bfaa4b227 | IOSurface deinit keeps the pixels | R | API (embedder keeps the last frame) |
| F42 | #43, #44 font rebuild, cell size | 459b2daaf .. 7d1c7600f | Row-key reuse; one rebuild per font change; cell size follows the font grid | R (all surfaces) | UP |
| F43 | #37 CSI 996 runtime scheme | 70f592bbf | CSI 996 and mode 2031 report the runtime scheme | D/U | UP as an option |
| F44 | #64 upstream v1.4.0 merge | 19cf86448 .. 64a7a1b1f | Zig 0.17 Apple fixes; snapshot restore across slicing | C+E | BUILD / API |
| F45 | #74 wrap fixes | 19ab1cbcb .. 34e73ba8b | Soft-wrap at scroll-region and cleared-row edges; formatter wrap carry | U (5 commits C) | UP |
| F46 | #74 link regex | 5410e5d44 dfd07de4a | One compiled link regex per pattern | U | UP |
| F47 | #70-#73, #75-#80 embedder present | 30b8490a1 .. ec398e8d3 (33; 9 are the same patch twice) | `set_host_present(EMBEDDER)`, `host_frame`, `host_frame_committed`, off-main gate, kept-frame rule, wake counters | E+R | replace by the synced renderer mode (sec. 4); UP the wake counters as part of `render_counters` |
| F48 | #74 sync fixups | 3f637268c a6b9048e9 4761223ca | Adapts fork code to upstream changes | D | goes away with the code it adapts |
| F49 | #85 prompt clear waits for shell | ec0060c7b .. e6d6eec09 | Opt-in `PROMPT_REDRAW_WAITS_FOR_SHELL` | E | UP (opt-in option) |
| F50 | upstream picks | 77fe41a73 (#15111), 8379ecc8a (#15121) | Backports; file blobs equal upstream 5d3f65332 | D | DROP at the next sync |

Counts (one primary class per commit, 294): C 38, E 97, E+R 73, R 42, U 30, U+R 4, D 10. 119 commits touch renderer
timing. The host-sized paths (F8, F38, F47, F15) are opt-in but cmux turns them on for every surface. Changes that
also hit a plain surface, so they can make cmux differ from Ghostty.app even with no host mode: F4, F9, F11, F30,
F36-F37, F40, F42.

Pin differences:
- `538a3e2ef..8379ecc8a` (#39026): only F50, upstream #15111 (one-scan style runs in `RowBuilder.scan`) and #15121
  (RefCountedSet reuses dead IDs). Both are upstream code: if a scroll cost moved here, Ghostty.app at the commit
  that has them moves the same way (the parity bench at that upstream commit shows it).
- `8379ecc8a..b3a5ebfdfe70` (#38206): 12 commits, all F15 (`ProgramRedraw` and its red tests, P0 12-16) and the merge
  b3a5ebfdf. Only the resize path uses READY_PROGRAM.

Upstream fixes after the base that the pin lacks and that touch scroll or resize: 15a443234 and 96d379822 (`endUpdate`
style-run performance), 321a32a42 (scrollback not pulled down when rows grow and columns shrink), 5ce2325ec (cursor pin
garbage flag after resize), 1b8b3f55b (pin remap when column backfill stops early). The next sync takes them (step 2).

Target after the plan: the fork is F2/F3 (replay)/F4 (iOS)/F5/F8 (`render_counters`)/F10/F12/F14/F15 (the detector)/F17-F18/F21-F22/F25-F26/F34/F38-F41/F44 reshaped as one embedding API
(external IO, snapshots, host size, reflow preview, copy-mode selection, link filter, color transition, present
callback, synced present mode), each a candidate upstream PR; every U patch is sent upstream; every D patch is dropped;
C moves to build scripts.

**Sync strategy (perf lead decision f3 item 6, 2026-11-10).** A full merge of upstream main is the standing way the
fork follows upstream. A pin made of cherry-picks (#40153: the five fixes above, picked onto the current pin) is a
stopgap. It stays only until the `ghostty-vt` rename compiles: upstream's libghostty-vt ABI freeze after the base
(657e82d1a, 796f09a6f, 12206bfb8, 0b7f9c156; fdedebade then makes upstream CI fail on an ABI change that is not an
addition) moves the formatter options to `ghostty_formatter_set/get`
and renames 28 symbols that `cmux-tui/crates/ghostty-vt` calls. The draft of the full merge is fork commit
`17b8ed38b` (branch `release/cmux-gi-pin-sync-1`, its 11 conflicts resolved, not compiled). When the rename
compiles, the pin moves to the full merge, F13, F31, F48 and F50 fold away there, and later syncs are merges, not
picks. Sending a patch to upstream Ghostty is Lawrence's call, patch by patch.

## 4. Resize sync inside Ghostty's renderer

Today the resize hold lives in cmux (P1-P8, P10-P12) and works against Ghostty: Ghostty draws a frame, cmux decides
in a run-loop pass on main whether to show it, and until it says `committed`, Ghostty sends every frame through main
(P3). That is why a resize policy can touch scroll and output frames. The fix: Ghostty's renderer owns the rule, on
its own thread, and the app only gives sizes.

### 4.1 The rule (the #38206 contract, moved)

When the surface size changes, the renderer thread:

1. Reflows at once and draws at the new size (it does this today).
2. Primary screen: presents that frame at once. The reflowed text is the right picture.
3. Alternate screen (a TUI): keeps the last presented frame (gravity top-left, clipped or padded, never stretched)
   until one of: the program redrew a whole picture at the new grid (`Terminal.ProgramRedraw`, today READY_PROGRAM,
   F15); or `bound` refreshes passed (default 3 = today's `resizeHoldTicks`). The count starts when the grid is
   known: `ghostty_surface_set_grid` for a mirror surface (the PTY owner announced it), the reflow for a local PTY.
4. Synchronized output (mode 2026) is unchanged: a resize must still end it (the as-built header of #40174 says "a
   resize ends it"). Where upstream ends the mode on a resize is not verified: at the base `Termio.resize`
   (`up:src/termio/Termio.zig:524-564`) does not clear the mode itself, and :600 is `resetSynchronizedOutput`, the
   timer reset.
5. The layer's `contents` and `bounds` change in ONE `CATransaction` on the thread that presents, so a frame is never
   shown at the wrong size. This is what P1 and P8 do in cmux today, one level up.

No other frame waits: a scroll, output or cursor frame at an unchanged size presents off main as today
(`setSurfaceOffMain`), with no `mainPending` route.

### 4.2 What the embedding API must expose

One flag and one callback:

- Flag: `ghostty_surface_set_host_present(surface, GHOSTTY_HOST_PRESENT_RENDERER_SYNCED)` with
  `ghostty_surface_set_resize_hold(surface, bound_refreshes)`, or one config key `resize-sync = alternate:3`
  (the upstream-friendly form: Ghostty.app gets the same TUI behaviour). It replaces `EMBEDDER`,
  `ghostty_surface_host_frame`, `ghostty_surface_host_frame_committed` and the host frame states.
- Callback: `present_cb(userdata, ghostty_present_s)` with `{width_px, height_px, cols, rows, reason, seq,
  host_time}`, reason = `reflow | program | bound | content`. It is called on the presenting thread after the commit,
  never blocks, and is opt-in. It replaces the `setContents:` override (P23) and gives the cmux-only
  probes P26/P27 their data. It is not a parity probe: sec. 1.3 parts 1-3 read the screen for both apps.

The app keeps: the layer position and the clip (P25, P9), `set_size` (P15), `set_host_sized` (P14),
`set_reflow_preview` (P16) and the scale transaction (P13).

### 4.3 How pane motion uses it

- Split, close, zoom and drag keep the draw-ahead (P9): the app calls `set_size` with the final size at the start of
  the motion. Ghostty applies 4.1 to that size; the app animates only the clip and the position of the host view.
- The present never waits on the app. The callback tells pane motion when the final frame is up, if it needs to
  know (for example to drop a placeholder). Reduce Motion and "no animation" snap in one frame: the frame at the new
  size shows when it is ready, and the old frame is clipped, as today's keep.
- Chrome (P10) no longer waits for the terminal frame: the frame is never wrong-sized, so chrome moves at once.
- What a person sees is the same as today on the primary screen and in a TUI: no stretched text and no half-drawn
  TUI. What changes: scroll and output frames can no longer be held or main-routed by a resize.

### 4.4 Why not keep the cmux hold

The cmux hold needs a main-thread pass per frame, a committed handshake, a watch list per window and a screen-switch
scanner (P11) that caches the terminal's own state. Ghostty.app has none of it and does not show the faults it
fixes only because it presents on main and drops wrong-size frames; the synced mode keeps that rule and moves it off
main. Risks: `ProgramRedraw` false positives (a TUI that draws in 2 frames), and a long GPU frame at a new size. Both
are bounded by `bound`, and the existing TerminalResizeProgramHoldTests are the tests that must cover them after the
move (step 4).

## 5. Migration, step by step

Each step is one PR (a pin PR where the fork changes). Each step has, in its PR body: the parity table of sec. 1.2
for the rows it touches, before (the feat tip) and after (the PR head), both against the same upstream Ghostty.app
arm; and a red-first regression test, committed failing before the fix, red and green results named. No step adds a
CI gate, job, step or perf-gate row. A step that makes any row worse than before beyond the spread does not land.

| step | change | rows that must not get worse / must pass | red-first test |
|---|---|---|---|
| 0 | Bench tools: `scripts/measure/ghostty-parity.sh`, `ghostty-parity-*` in `release_bench_tags`, the hid_inject scroll step, a 120 Hz ScreenCaptureKit stream with a time per frame, the SCK marker-row probe, the per-thread time sampler, the Ghostty.app driver, the upstream app fleet build (Zig 0.17) | none (tools only); baseline table at the feat tip (sec. 6) | the probe's own test: a known scroll delay injected in a fixture app is read back within 1 frame |
| 1 | P3 risk: main routing stays on after a watch is dropped (read only, not run) | S1-S5, O1 | a presenter unit test: drop a watched surface mid-pass, then a same-size frame must present off main |
| 2 | Pin sync to upstream main (takes 15a443234, 96d379822, 321a32a42, 5ce2325ec, 1b8b3f55b; drops F13, F31, F48, F50) | all rows | a scroll fixture: style-run `endUpdate` cost per row stays under the upstream value (Zig test in the fork) |
| 3 | `present_cb` in the fork; P23 swizzle deleted; P26/P27 read the callback | T1 | a test that a present at size S reports S and the reason `content` |
| 4 | `RENDERER_SYNCED` mode ON for every surface; delete P1-P8, P10-P12 and the fork's EMBEDDER/host-frame code (F8, F47 rest) in the same PR | R1 must pass; S1-S5, O1, T1 not worse | keep TerminalResizeProgramHoldTests and TerminalKeyResizeFrameTests (moved to drive the fork); new test: a scroll and an output frame during a resize hold are never routed through main |
| 5 | In-place restore API (reset and restore on one surface, with `hold_frames`); delete P18; delete P17 after its OSC 11 repro test | O1, T1; first-frame time after restore | the OSC 11 before-window repro test; a restore test that the last frame shows until the restored frame, with no 500 ms overlay |
| 6 | Fork diet: send every U patch upstream (sec. 3), drop each at the sync that brings it; keep only the embedding API | all rows at each sync | each upstreamed patch keeps its red test upstream |
| 7 | Transport (old doc G3/G4/G5, PL-daemon): app -> daemon -> host input and output hops | S3, S4, T1 must pass | the key -> frame probe at n = 20 against Ghostty.app |

Order: 0 first (no number, no step). 1 and 2 are independent. 4 needs 3 (it builds on the present callback; R1 is proved by the step-0 screen probe). 5 and 6 after 4.
7 runs beside 4-6, owned by the PL-daemon owner.

### 5.1 State of the steps (2026-11-10, feat `7d3e8472628`, pin `b3a5ebfdfe70`)

No step is merged. No PR below has a parity table with numbers: each says `not measured` (no quiet 120 Hz host, and
the step-0 tools do not exist). The order rule above ("0 first") is thus not met by the open PRs; each one must get its
rows measured before it lands, or the lead must write why not in the PR.

| step | PR | state | where the PR differs from this design |
|---|---|---|---|
| 0 | none | not started | - |
| 1 | #40055 (S-P3) | open | App side only: a watch that runs out keeps the commit owed. Step 4 deletes the presenter it changes. |
| 2 | #40153 (GI PIN SYNC) | open | NOT the full sync: fork branch `release/cmux-gi-pin-sync-2`, pin `a0975fd8c` = the current pin + red-test commit `9ae6954e2` + `cherry-pick -x` of 5ce2325ec, 1b8b3f55b, 321a32a42, 96d379822, 15a443234. F13, F31, F48 and F50 stay until the full merge (sec. 3, sync strategy). The `endUpdate` cost test of the table is not written. |
| 3 | #40169 (GI PRESENT CB) | open | Fork branch `release/cmux-gi-present-cb-1`, pin `a0e665d4f`. The API is `ghostty_surface_set_present_callback(surface, cb, userdata)` with `ghostty_surface_present_s { width_px, height_px, reason, seq, host_time }`: no `cols` / `rows`, and two reasons (`GHOSTTY_PRESENT_CONTENT`: same pixel size as the frame before; `GHOSTTY_PRESENT_RESIZE`: another size, or the first frame), not the four of 4.2. On the main thread the callback runs inside main's open transaction, before its commit; off main it runs after the commit (4.2 says "after the commit"). It deletes `TypingFrameProbe.swift` (P23). |
| 4 | #40174 (GI RENDERER SYNC) | draft, stacked on #40169; held by the perf lead until its ported tests run green | Fork branch `release/cmux-gi-renderer-sync-1`, pin `c31377f1a` (on `a0e665d4f`). `GHOSTTY_HOST_PRESENT_RENDERER_SYNCED = 2`; the bound is fixed in the fork (3 refreshes of 120 Hz): no `ghostty_surface_set_resize_hold` and no `resize-sync` config key. The bound counts from the size change and a `ghostty_surface_set_grid` restarts it (4.1 rule 3 starts it at the grid). The grid-report refresh tick moves from the presenter to a new per-window `TerminalGridReportRefreshes`. A frame of a NEW size still shows through the main thread, in main's Core Animation transaction with the view's bounds (4.1 rule 5 says "the thread that presents"); a frame at the shown size goes off main, except for one run loop pass after main changed the shown size. The presenter's draw-ahead (P9's presenter part) is deleted: the final size goes to Ghostty at the motion's start (4.3). It ports or maps the old presenter tests (`TerminalResizeProgramHoldTests`, `TerminalKeyResizeFrameTests`, `TerminalWindowFrameSyncTests`, `TerminalFrameOwnerMainThreadTests`) and deletes `TerminalScreenSwitchWatch` (P11). |
| 5 | none | not started | - |
| 6 | none | not started | The sync strategy of sec. 3 comes first. |
| 7 | none | not started | - |

Pins: the fork branches of #40153 (`a0975fd8c`) and of #40169 (`a0e665d4f`) both start at `b3a5ebfdf` and neither
has the other's commits; `c31377f1a` (#40174) has #40169's commits and not #40153's. The second of them to land needs
a fork branch that has both, and a new pin: a pin PR must not drop what an earlier pin PR landed. `b37a94dfe`
(`release/cmux-gi-land-1-cell-guard`) = `c370b103a` + the two commits of fork PR #91 (a frame with no built cells runs
no cell pass; cmux f14); it has no commit of #40174.

## 6. Baseline

**Not measured** (still true at 2026-11-10 07:55Z). At 01:38Z and 01:43Z the controller
(`http://100.89.225.106:18765/status`) did not answer (curl status 000). No job was submitted. The step-0 tools (sec. 1.3) do not exist yet, so even an online fleet gives
only the cmux side of S1-S2 and O1 today (the kit's `render_counters` fps), not a parity table.

Exact commands, run from a worktree at the feat tip (`SHA`):

```sh
# cmux arm: Release with bench hooks. `ghostty-parity-*` is not in `release_bench_tags`
# (scripts/cmux-next/cmux-next.dogfood.conf) at the tip, so this tag gives a plain Release with no debug.* socket:
# step 0 adds the glob. Until then use a tag that matches `chrome-parity-*`.
cmux-ci build cmux --ref SHA --tag ghostty-parity-base-v1 --release --backend-mode local \
  --receipt artifacts/fleet/SHA-submit.json
cmux-ci wait JOB            # a timeout leaves the job running: wait again, never resubmit

# kit journeys (NIGHTLY REGRESSION, branch nr/cmdt-latency-never-merge 40b6699592b), ABAB, n = 20 per arm
for j in scroll-zsh scroll-tui scroll-zsh-big scroll-tui-big; do
  /work/tmp/nightly-regression/tools/round.sh cmux JOB "$j" HOST
done
python3 /work/tmp/nightly-regression/tools/scroll_summary.py RUNS_DIR

# upstream arm and the full table (after step 0 lands the script and the upstream app build at c7f68a7f48c6)
cmux-ci run --class exclusive --measurement --key ghostty-parity \
  --script scripts/measure/ghostty-parity.sh --ref SHA \
  --arg --cmux-job=JOB --arg --upstream-ref=c7f68a7f48c6 \
  --arg --rows=S1,S2,S3,S4,S5,T1,O1,R1,I1 --arg --n=20 --arg --abab
```

`--script` must be on the controller allowlist: step 0 adds `scripts/measure/ghostty-parity.sh` there (an hq change).
The script makes the 120 Hz 2x virtual display itself (`--vdisplay 120x2` is a flag of `scripts/journeys/run.py`) and
gives `not run` when the measured rate is not within 0.35 ms of 8.333 ms.
Risk for step 0: the fleet Macs' PATH Zig is not 0.17.0 (the perf lead's probe of 2026-11-10 07:22Z found 0.16.0 on
the five AWS minis it read), and upstream needs 0.17.0: the script must install a job-local 0.17.0, as
`GHOSTTY_ZIG_SOURCE=ghostty-next ZIG_FORCE_LOCAL_INSTALL=1 ZIG_PUBLISH_ENV=CMUX_VT_ZIG ./scripts/install-zig-ci.sh`
does for the nightly (#40139).
The pin author puts the printed table into the pin PR.
