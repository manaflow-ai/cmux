# p03-rendering: one frame clock, render-server motion, pages as layers, damage, Ghostty off main

Program spec, final (fixer pass over the design and 3 reviews). Base: perf/chrome-parity at 772cdfc45ac
(= origin/feat-cmux-next). Counts come from `rg` over `Packages/macOS/CmuxNext/Sources` at that commit unless a
line names another path. Fixer re-checks (2026-10-25) are marked "(checked)".

Scope in one sentence: the main thread decides geometry once per change and commits it; the render server
animates it; content producers render on their own threads at the vsync of their display; nothing on main runs
per animation frame; nothing is invalidated unless a value changed.

Faults owned: F4 (motion = live resize of real frames every frame), F1 (Chromium pages are child windows; shared
with PL-cef-layer), the render half of G1/G4/G6/G7 (ghostty-integration-DESIGN), and the render half of the idle
and hidden-is-free targets.

## 1. Chrome reference

Paths are in chromium/src at HEAD (read 2026-10-25).

1. One frame clock per display. `ui/display/mac/display_link_mac.h`: `DisplayLinkMac::GetForDisplay(display_id)`
   returns one ref-counted link per display that all consumers share. `RegisterCallback()` returns a
   `VSyncCallbackMac`; the callback runs "on the register thread" (`display_link_mac.mm` posts the tick with
   `base::BindPostTaskToCurrentDefault`, or runs it on the link thread). So Chrome has one link per display and
   fans it out to many threads. `components/viz/service/frame_sinks/external_begin_frame_source_mac.h` turns ticks
   into BeginFrames; `components/viz/common/frame_sinks/begin_frame_args.h` carries frame_time, deadline,
   interval and sequence. `components/viz/service/display/frame_rate_decider.h` picks the rate from what clients
   ask for.
2. Deadlines. `docs/how_cc_works.md`: the cc::Scheduler "maintains a deadline by which it expects its embedder to
   respond. If the main thread is slow to respond, then the Scheduler may draw without waiting for a commit"
   (`cc/scheduler/scheduler.h`, `scheduler_state_machine.h`). A frame never waits for a slow main thread.
3. Threaded animation, and its limit. cc runs keyframe animations of transform, opacity and filter on the
   compositor thread (`cc/animation/animation_host.h`, `keyframe_model.h`). In Views,
   `ui/compositor/layer_animation_element.cc` threads only `ThreadedTransformTransition` and
   `ThreadedOpacityTransition`; `BoundsTransition`, `ClipRectTransition` and `RoundedCornersTransition` step on
   the main thread, and `BoundsAnimator` sets View bounds on main each frame. So Chrome's rule "layout once, the
   compositor animates" holds for transform and opacity only. cmux goes further on purpose: Core Animation can
   animate `bounds` and `position` on the render server. The cost is that sublayer layout does not follow an
   animated bound (CA applies `autoresizingMask` in `-layoutSublayers`, at commit, for the model value), so every
   dependent sublayer needs its own spring (task 029).
4. Threaded scrolling. `cc/input/input_handler.h` scrolls on the compositor thread; scrollbar layers update
   "without going back to the main thread". AppKit's equivalent is responsive scrolling (task 110).
5. Damage. `cc/trees/damage_tracker.h` computes damage per frame; `components/viz/service/display/
   display_damage_tracker.h` and `surface_aggregator.h` merge it; partial swap "saves power". On macOS,
   `ui/accelerated_widget_mac/ca_renderer_layer_tree.h` `CommitScheduledCALayers(..., old_tree, ...)` reuses the
   old CALayers "as much as possible" and touches only changed ones. Raster runs on worker threads
   (`cc/tiles/tile_manager.h`). Image decode runs off main (`cc/tiles/image_controller.h`).
6. Pages as layers, input in the same view. `ui/accelerated_widget_mac/display_ca_layer_tree.h` shows
   compositor output in a layer-hosting NSView through a `CALayerHost` on the GPU process's `CAContext`
   (`GotCALayerFrame(ca_context_id)`); the GPU process commits its own context
   (`gpu/ipc/service/image_transport_surface_overlay_mac.h`). Input, IME, cursor, drag, popups and accessibility
   come from the same NSView: `content/app_shim_remote_cocoa/render_widget_host_ns_view_bridge.h` owns
   `RenderWidgetHostViewCocoa`, "the NSView used for input and display", whose background layer roots the
   `DisplayCALayerTree`. `content/browser/renderer_host/render_widget_host_view_mac.h`
   `MigrateNSViewBridge(remote_cocoa::mojom::Application*, parent_ns_view_id)` moves that view into another
   process's view tree (PWA app shims). Chrome never forwards input from an off-screen window.
7. Resize sync. `ui/accelerated_widget_mac/ca_transaction_observer.h` (`CATransactionCoordinator`) pumps the UI
   thread in pre-commit up to `kUIPaintTimeout` (500 ms) and in post-commit up to `kPostCommitTimeout` (50 ms).
   `kOnlyUseWindowResizeHelperOnResize` shortens the pre-commit wait to 1 ns outside live resize (off by
   default). cmux must not copy the blocking wait; it uses the fence-port form (`-[CAContext setFencePort:]`,
   also used by WebKit's RemoteLayerTree resize): the render server waits, the main thread does not.
8. Surface sync with deadlines. `cc/layers/deadline_policy.h` (`UseDefaultDeadline`, `UseSpecifiedDeadline(
   frames)`, `UseInfiniteDeadline`); viz holds a parent frame until the child surface at the new `LocalSurfaceId`
   arrives or the deadline passes (`components/viz/service/surfaces/surface.h`).
   `content/browser/renderer_host/delegated_frame_host.h` fills the gap with the page's gutter color. A tab draws
   through its window's compositor (`browser_compositor_view_mac.h`: "We are drawing using |parent_ui_layer_|'s
   compositor"), so page and browser UI are one aggregated frame.
9. Hidden costs nothing. `content/app_shim_remote_cocoa/web_contents_occlusion_checker_mac.h` adds Chrome's own
   occlusion check because macOS fails "for browser windows of similar size" (crbug.com/883031). Hidden
   renderers stop producing frames. `components/viz/client/frame_eviction_manager.h` is one global LRU of saved
   frames ("keep a minimum amount, as an LRU cache, to make switching between a small set of tabs faster"), with
   a soft limit from memory, locks for visible frames, a periodic cull (`kPeriodicCullingDelay`, 5 min) and a
   purge on memory pressure. Views are hidden and frames evicted; native views are not detached.
10. Field metrics. `cc/metrics/dropped_frame_counter.h` and `frame_sequence_tracker.h` count drops from
    BeginFrame sequence numbers plus `gfx::PresentationFeedback`; `cc/metrics/event_metrics.h` EventLatency ends
    at the presentation timestamp. These run in the compositor/viz, not on the browser main thread.
11. Battery saver throttles frame rate (`components/performance_manager` battery saver mode).

## 2. cmux today

Frame clock
- One CADisplayLink per NSWindow (`CmuxNextWakeups/FrameScheduler.swift:213`, `window.displayLink`), plus one for
  `FrameScheduler.app` and one for MainWorkScheduler's budgeted scheduler (main screen): up to 3 links for one
  window on one display.
- Ghostty: one CVDisplayLink per surface, each on its own CV thread (ghostty-next 723c4ab
  `src/renderer/generic.zig:1404`, `DisplayLink.createWithActiveCGDisplays`). The submodule is NOT initialized in
  the checkout (`git submodule status ghostty-next` = `-723c4ab93e70`, checked), so every ghostty-next rg
  returns nothing; done checks must initialize it first (task 005).
- 24 `FrameClient(owner:` sites (checked) and 3 MotionClock steppers: DisplayLinkDriver, TabStripView
  autoscroll (`TabStripView+Layout.swift:370`), SidebarCardSlotMotion.

Motion (F4)
- `ScreenContentView.step` / `applyPresentation` (`CmuxNextLayout/Views/ScreenContentView+Motion.swift`,
  perf-hot 4 ms motion-frame) run on main every frame: CPU springs (`SpringValue`, `AnimatedFrame`),
  `host.frame = placed` plus `layoutSubtreeIfNeeded()` per resized pane, `clipToStrip` with cutouts
  (`ScreenContentView+Dock.swift:81`; cutouts exist only because page windows draw above views), divider frames,
  `refreshDividerHover`, `overlayNeedsSync`, `stepRows`, `stepAreas`, camera scroll.
- `ScreenContentView.swift:22-62` holds `paneFrames: [PaneID: AnimatedFrame]`, `dividerFrames`, `scroll:
  SpringValue`; `ScreenContentView+Visibility.swift:107` reads the displayed AnimatedFrame; `LayoutRootView`
  calls `updateVisibility()` from `advanceFrame` (`LayoutRootView.swift:452`) every frame (checked).
- AppKit-stepped animations outside the layout (checked):
  - sidebar slide: `SidebarContainerView.swift:364` `Motion.animator(widthConstraint, in: self).constant`; its
    comment says "descendants re-lay out each frame at their real size", and `ResizeCoordinator.swift:15` says a
    sidebar slide changes every pane's size every frame;
  - titlebar band: `CollapsedBandReveal.swift:119/121/130` animate a width constraint;
  - Toggle Omnibar: `BrowserChromeView+Toolbar.swift:23` animates `toolbarHeight` (page resizes per frame);
  - 11 `animator().frame|setBoundsOrigin` in CmuxNextSidebar; 36 `Motion.<category>.animate(` sites, which on
    macOS 15+ go through `NSAnimationContext.animate(SwiftUI.Animation)` (`Motion+AppKit.swift:174`);
  - window-server animations: `WindowZoom.swift:50` and `QuickComposerPanel+Floating.swift:55`
    `animator().setFrame`, `ChiefPetController.swift:209` and `HoverCardMotion.swift:74/81/88` panel alpha,
    `WindowCloseMotion.swift:57` per-frame `window.alphaValue`, `TabDragGhostPanel.swift:135` per-frame panel
    move, LinkDragGhost and workspace drag ghosts.
- Measured: panes.close.4x2 33.3 ms/frame, panes.zoom.4x2 26.0 ms (perf-lead row 2); New Column at 30 panes
  41 ms p95 (row 3).
- Already done: tabs animate on the render server (MotionPath, perf I7); terminals get their final grid in the
  key's turn and hold rest-size content during a split or close spring (ghostty-integration-DESIGN 4d,
  Lawrence 2026-10-24); `SidebarDragSpring` uses additive render-server springs for row drags.
- `GlassBackdropFeed` evaluates JS in each page on the next frame after every geometry change; 22 frame/bounds
  notification observers in 9 files run each motion frame.

Chromium pages (F1)
- Each page is a child NSWindow (fork `CmuxParentViewTracker`). Layer hosting (fork API 26,
  `CEFLayerHosting.swift`, `CEFHostedPageView.swift`) is coded, but `browserResize.layerHosting` defaults to false
  (`BrowserResizeTunables.swift:24-27`) and the pin (`scripts/cmux-next/cef-manifest.json`:
  `cef-154.0.28-cmux.28`, `cmux_cef_api_version` 24) cannot host.
- Resize waits: below API 27, `CEFSwitches.swift:68` adds `enable-features=AsyncLiveResize`, which skips
  `Synchronize()` in `UpdateWindowGeometry`, so the 500 ms pre-commit and 50 ms post-commit waits do not run
  today. At API >= 27 the switch is dropped, and cef-layer-hosting-DESIGN section 1 says the post-commit wait
  returns until the fork skips `Synchronize()` for a 0 deadline (sent to PL-cef-layer for cmux.33). So a naive pin
  bump re-adds a main-thread wait (checked; task 041).
- Pump: the fork slices `CefDoMessageLoopWork` at `--cmux-pump-time-slice-us=2000` (`CEFSwitches.swift:28,59`);
  `CEFPumpSchedule.timeSlice` 10 ms is the safety net (checked). The slice does not know the frame deadline.
- Child-window-only code: 26 hits of `cmuxClipPath|cmuxOcclusionRects|browserChildWindowPagesNeedUpdate|
  postGeometryChange` in 11 files, `DividerMouseCatchers` panels, the `WindowOverlayHost` child panel, 27
  `addChildWindow` sites in 21 files.
- Workspace switch with pages: 46.2 ms input to commit (row 4).

Damage and invalidation
- No damage accounting; only `LayoutPassGuard` counts `NSView.layout()`.
- 445 `needsLayout = true|needsDisplay = true` hits in about 170 files (Sidebar 173); 80 forced sync layout or
  flush hits (`layoutSubtreeIfNeeded|displayIfNeeded|.display()|CATransaction.flush`); 59 files override
  `updateLayer` with no `layerContentsRedrawPolicy`; 23 `draw(_:)` overrides (checked); 11 files set
  `shadowOpacity` with no `shadowPath` (checked); 39 files override `updateTrackingAreas` and use
  `.inVisibleRect` (checked); 0 `isCompatibleWithResponsiveScrolling` (checked); 10 infinite CA loops; 19
  `NSImage(data:|contentsOf:)` (checked); 27 files read occlusion state on their own, 15 of them observe
  `didChangeOcclusionStateNotification` outside Debug files (checked).
- Home typing under load: `NSViewBuildLayerTreeForDisplay` 15-21 % of main (row 5).
- Ghostty redraws the whole surface; a focused steady terminal draws every 600 ms (G7).
- App web pages (webviews/): 26 `infinite` CSS animation lines, 98 `requestAnimationFrame(` calls, 19
  `setInterval(` calls (checked; the review's 47/531/24 counted differently).

Ghostty and other producers
- Each renderer frame `dispatch_async`es to main to set `layer.contents` (ghostty-next
  `src/renderer/metal/IOSurfaceLayer.zig:98-127`): one main turn per frame per terminal.
- The G1 pre-commit presenter waited up to 4 ms on main and did not land.
- `GhosttyRuntime.swift:97` installs `wakeup_cb`; `RuntimeCallbackContext` (line 388) collapses bursts, but no
  frame bound exists.
- `PhoneScreenView.swift:47/53` and `LayerContentsPresenter.swift:39` set contents per frame on main.
- In-tree off-main pattern: `CmuxNextRemoteView/Present/MetalFramePresenter.swift` (CAMetalLayer,
  `presentsWithTransaction = false`).

Measurement tools
- `DebugWindowRecord` and `DebugFrameProbe` are main-thread FrameClients; `DebugWindowRecord.swift:66` takes a
  synchronous composited snapshot each frame. They add the main work they measure and see main-tick times, not
  render-server present times. They stay for visual proof, not for DC2/DC3 timing.

## 3. Target design

### R1 One clock per display (Chrome DisplayLinkMac)
- `CmuxNextWakeups/DisplayClock.swift` owns one link per `CGDirectDisplayID`. Every FrameScheduler (window,
  app, budgeted) subscribes to its display's clock; a window moves on `didChangeScreen`.
- The link runs on the `VSyncHub` thread (one per display, QoS userInteractive). Off-main producers (Ghostty)
  get their callback on that thread; main subscribers get a coalesced post to main (at most one pending), which is
  Chrome's post-to-register-thread. Fallback, chosen only by measurement in task 014: if the hop adds >= 0.1 ms p99
  to main tick latency, keep a main link plus the hub link per display.
- Each `FrameTick` carries BeginFrame args: timestamp, targetTimestamp (deadline), interval, sequence.
- The link runs only while a client is armed, at the highest rate any armed client asks for (FrameRateDecider:
  motion 120, ui 60, ambient 30), with Low Power Mode and thermal caps.
- MainFrameBudget stops budgeted work at targetTimestamp minus the measured main CA commit plus layout p95.
- The in-process CEF pump slices to the same deadline.

### R2 Commit once, animate on the render server (behind a seam and a tunable)
- `MotionBackend` seam with `cpuStep` (today) and `renderServer`; Tunable `motion.renderServer`, default off until
  task 022c. Each motion kind implements its render-server variant in its own file, so 13 tasks run in parallel.
- A structural change builds a `PaneMotionPlan` in the key's turn: a pure value of from/to rects for each changed
  pane, divider, camera, and pane-chrome sublayer, plus appear/disappear; O(changed).
- Main sets each NSView frame to rest once and lays out once, then adds `RenderSpring` animations. RenderSpring is
  additive only: a retarget adds a new additive spring from (old model - new model) to 0 with initialVelocity 0;
  the running springs carry the velocity. Per-component key paths (`position.x`, `position.y`,
  `bounds.size.width`, `bounds.size.height`) where a release velocity must be set. No MotionPath or SpringValue
  read on the retarget path.
- Animations go on a dedicated motion container layer per pane (decided by spike task 016), never on a backing
  layer AppKit rewrites.
- Every chrome sublayer that does not scale (ring, glow, dim, border, edge-anchored items) gets its own spring
  with the host's token and the same beginTime; nothing depends on `autoresizingMask` during a spring.
- Landing is a CATransaction completion. No FrameClient ticks during a structural spring. Main work per motion
  frame = 0.
- Hit testing during a spring maps through `layer.presentation()` of the moving panes (O(changed)); tracking areas
  and cursor rects refresh at landing; divider grabs mid-spring wait for landing.
- Gestures stay per input event at O(1): a strip pan sets one motion-container property, with a hitTest offset;
  NSView geometry commits once at gesture end; a fling is a RenderSpring with the release velocity.
- Content: terminals keep 4d (final grid in the key's turn, rest-size content anchored to an edge). Pages resize
  once at spring start inside one CA fence for all resized pages (deadline 2 frames), so the page's new-size frame
  and the host's first spring frame commit together (Chrome surface sync); the gap shows the page background
  (Chrome gutter). Divider drags and window live resize resize content per event (fence per transaction).
- AppKit-stepped animations (sidebar slide, band reveal, Toggle Omnibar, sidebar frames, `MotionGate.animate`,
  NSWindow animators, drag ghosts) move to the same model.

### R3 Chromium pages are layers, with input in the same NSView
- 72 h deliverable (Track A): pin a fork with API >= 27 and fence resize, take page visibility from the embedder,
  turn layer hosting on by default with the API 26/27 transparent input window, show/hide in the switch's
  transaction, and one HiddenFrameLRU.
- Stretch in the 72 h (Track B, Chrome's model): the fork attaches the page's `RenderWidgetHostViewCocoa` as a
  child of `CEFHostView` (in process). Pixels, input, IME, cursor, drag, popups and AX then come from Chromium's
  own Cocoa view; the page window stays a `views::Widget` and never orders in. Once Track B is on, delete the
  catcher panels, the overlay child panel, the clip/occlusion path and the cutouts. All fallback code lives in one
  file, `CmuxNextBrowser/CEF/ChildWindowPageFallback.swift`.
- The helper-host form (remote_cocoa `Application` mojom over the helper's XPC) belongs to the F2 program
  (PL-cefhost); p03 keeps the in-process API shape the same so F2 can reuse it.
- The cmux-side input forwarding plan of the design (old tasks 044-049: PageInputForwarder, NSTextInputClient on
  CEFHostView, drag and AX re-implementations) is dropped: Chrome does not do it, the helper design estimates the
  same fork work at 3-4 weeks, and Track B gets the same result from Chromium's own view.

### R4 Damage tracking and invalidation discipline
- `RenderStats` counts per display frame and per owner: view frame sets, `layout()` calls, `updateLayer`/`draw`
  calls and area, contents sets, window-server calls, `addTrackingArea` calls, looping animations in hidden views.
  Swizzles are installed only while `debug.frames` or `debug.damage` is armed, and removed when disarmed; counters
  are atomic. Timed bench passes run with RenderStats disarmed.
- Rules: every invalidation sits behind a changed value or carries `// invalidate: <why>`; layer-backed views use
  `.onSetNeedsDisplay` or `.never`, with stretch-safe contents; no forced sync layout or flush without
  `// sync-layout: <why>` (pre-push guardrail, not CI); looping CA animations come off when hidden or occluded;
  pane and window chrome uses frame layout, not Auto Layout; shadows have a `shadowPath`; `.inVisibleRect`
  tracking areas are added once; images bound to layers are decoded off main.
- Invalidation clean-up is driven by measured damage owners (task 003), not by a blanket rewrite.
- Terminal cursor blink runs on the render server with real cursor-cell contents. Ghostty draws no frame when
  nothing is dirty, and redraws only rows dirty since that buffer's last use (buffer age, purge-aware).
- Idle damage target: 0 rects/s.

### R5 Ghostty and other producers present off main
- Spike task 017 picks one of: (a) CAMetalLayer per surface, present on the renderer thread with
  `presentsWithTransaction = false` (the in-tree MetalFramePresenter pattern; gives presentedTime), or (b) a
  per-renderer CAContext committed by the renderer thread and shown through a CALayerHost (Chrome's GPU form).
  Rejected: a renderer-thread CATransaction into a layer of the main-owned tree (lock contention with main's
  commit, priority inversion, teardown race).
- One writer of the presented contents: the renderer. Main hides, shows and purges through a Ghostty API. The
  resize pre-commit present (G1) never waits, and any two-writer path uses a monotonic frame sequence
  (compare-and-swap) so an older frame never overwrites a newer one.
- External vsync from VSyncHub replaces the per-surface CVDisplayLink; only dirty, visible surfaces arm.
- Grid, snapshot and status events stay on the lane; main gets one coalesced status per frame; `wakeup_cb` ticks
  coalesce to one per frame.
- Manual-IO surfaces run no IO thread; glyph atlases and the MTLCommandQueue are shared per device; renderer QoS
  follows visibility and focus.
- Phone live screen and RemoteView presenter A use the same off-main pattern.

### R6 Hidden and occluded cost nothing (render side)
- A hidden workspace root is hidden (`isHidden`) in the switch's turn, not detached; content is evicted as its
  own step (terminal purge, page frame eviction). Detach happens only after the grace as budgeted idle work, and
  only if measurement shows it pays.
- One `WindowOcclusionFamily` per window with Chrome's same-size-window check; every reader subscribes to it.
- One app-wide `HiddenFrameLRU` (Chrome FrameEvictionManager) for page frames and terminal last frames.
- App web pages pause infinite CSS animations and rAF loops when hidden or occluded.

### R7 Measurement (no CI gates; agents run these on the fleet)
- Timing: `motion-hitches.py` (xctrace Animation Hitches plus a Time Profiler of main, and a separate-process
  ScreenCaptureKit timeline) at `--vdisplay=120`. No FrameClient runs in the app during timed passes.
- Counts: `motion-main-work.py` counting passes with RenderStats armed.
- Release field data: late main commits during motion and `action.presented_estimate`, with no main link started
  by the counter; true presented times where they exist (Ghostty presentedTime after task 080).
- Distributions p50/p95/p99/max, light and STRESS, macOS 26 and 27. Tart 14/15 for behavior only.

### Recorded decision for Lawrence (F4 vs render-server motion)
perf-lead F4 and cef-layer-hosting-DESIGN "Live resize" (Lawrence 2026-10-23) say every motion frame shows
content laid out at that frame's size. Lawrence's later 4d rule (2026-10-24) already gives terminals their final
grid in the key's turn with rest-size held content. R2 does the same for pages (one fenced resize at spring start,
page background in the gap). This program does not change the default by itself: R2 ships behind
`motion.renderServer` (default off). Task 022c flips the default only after it records the decision, the measured
reason (cef-resize-sync-bench.py: a Chromium page cannot give a frame per 8.3 ms for 12 pages) and a capture video
of Cmd-D and Cmd-W with a Chromium pane in perf-lead F4 and cef-layer-hosting-DESIGN. A per-frame fenced page
resize stays available as `browserResize.springPageResize = perFrame` for comparison.

## 4. Rules for implementers

1. Main work per motion frame is 0 for structural springs. A remaining per-frame main path is either input-driven
   and O(1) per event (`// input-driven:`) or a FrameClient with `// frame-client: <why>`.
2. Never put an explicit animation on a layer AppKit rewrites; use the motion container layer from task 016.
3. RenderSpring is additive only. Retargets add a delta spring with initialVelocity 0. Every animation goes
   through a motion gate (`Motion.<category>`); with the gate off the change lands in one frame and completions
   still run. check-motion.sh passes.
4. No dependent sublayer relies on `autoresizingMask` while a spring runs.
5. No non-main CATransaction touches a layer whose superlayer belongs to an NSView.
6. No main-thread wait for Chromium: fences and deadlines in frames only. No pin bump may re-add the post-commit
   wait (task 041).
7. Every invalidation has a changed value or a reason comment; every forced sync layout has `// sync-layout:`.
8. Hidden and occluded content: no loops, no vsync subscription, no frames.
9. Red first: every task that fixes behavior or performance commits its failing regression first, runs the same
   focused command red at base and green at head on the fleet (`cmux-ci run --class isolated`), and writes both
   results in the commit message (CLAUDE.md testing policy).
10. No new CI jobs, steps, gates or CI-lane tests (Lawrence 2026-10-23). New Python tests register with
    `lane = "manual"` in `tests/test-execution.toml`, with the reason. The sync-layout rule is a pre-push guardrail.
11. No local builds or tests on the person's Mac; all Swift/Zig/CEF builds and tests run on the fleet.
12. Tell the OWNERS.md owner before editing an owned file: PL-motion-core (ScreenContentView+Motion*, Dock*,
    LayoutRootView*, PaneHostView, DisplayLinkDriver), PL-motion-cef (WindowOverlayLayer, WindowOverlayHost*,
    DividerMouseCatchers), PL-cef-layer (CEFHostView*, CEFClipShape, Shim/), PL-ghostty (CmuxNextTerminal,
    ghostty-next), PL-typing (HomeComposer, TypingLatencyProbe), PL-switch (WindowState, WindowController),
    PL-guardrails (guardrails.py, perf-hot-benches.json), the Performance Lead (Wakeups, Motion).
13. Ghostty work lands as manaflow ghostty-next PRs first, through the integrator lane (task 079): at most 3
    GhosttyNextKit pins in the 72 h.
14. Each ghostty-next task runs `git submodule update --init ghostty-next` in its test phase and states its
    acceptance rg in the fork PR and in the pin bump.
15. Every native UI change shows a real capture (`cmux-ci capture`) or `No capture: <why>`.

## 5. Done checks

Each check is run by an agent on the fleet or locally (`render-done-checks.py`); none is a CI gate.

- DC1 one link per display: `rg -l 'displayLink\(target:|CADisplayLink\(|CVDisplayLink' Packages/macOS/CmuxNext/Sources`
  prints only `CmuxNextWakeups/DisplayClock.swift` and `CmuxNextWakeups/VSyncHub.swift`; with ghostty-next
  initialized at the pinned gitlink, `rg -c createWithActiveCGDisplays ghostty-next/src` reaches the call only when
  `vsync_external` is off (test in task 082); `debug.wakeups` live display links = number of displays with an
  armed subscriber (2 windows on one display during Cmd-D in both with 2 busy terminals: 1), or <= 2 per display
  if task 014 recorded the measured fallback; 0 at idle.
- DC2 render-server motion (counts): on aws-m4pro (macOS 26 and 27) at `--vdisplay=120`, with
  `motion.renderServer` on, motion-main-work.py counting passes over Cmd-D, Cmd-Shift-D, Cmd-W, zoom, New Column,
  close-last-column, workspace switch, sidebar toggle, Toggle Omnibar, band reveal, window zoom, hover card,
  sidebar reorder, light and STRESS (perf-stress-session.py 4x3, Chromium selected): RenderStats view frame sets
  (frames 2..n) = 0, `NSView.layout()` (frames 2..n) = 0, MotionClock 'layout' frames during a structural spring = 0,
  `updateVisibility` <= 2 per spring.
- DC2t render-server motion (time): motion-hitches.py over the same scenarios: main-thread work per spring frame
  from samples p99 <= 0.5 ms; no FrameClient live during timed passes.
- DC3 0 dropped frames in motion: motion-hitches.py hitch count = 0 for each DC2 scenario, light and STRESS,
  3 rounds; the separate-process capture timeline shows no interval > 1.5 x 8.33 ms.
- DC4 spring parity: RenderSpringParityTests max deviation between the additive CASpringAnimation (sampled through
  `presentation()`) and `SpringValue.step` <= 0.25 pt at 240 samples for every MotionSpring token; perpendicular
  retarget keeps value and velocity continuous; PaneSublayerParityTests: every chrome sublayer edge within 0.5 pt
  of the host at 25/50/75 %; motion-parity.py passes.
- DC5 key to frame: bench-typing.py and typing-frame-bench.py, terminal at a prompt, 120 Hz, light and STRESS:
  p50 <= 8.3 ms, p99 <= 16.7 ms; Home composer and omnibar the same rows.
- DC6 Ghostty off main: 10 terminals running `yes` for 10 s: `debug.terminal_display` main_presents = 0; main
  turns caused by terminal output (owners TerminalSession and GhosttyRuntime.tick) <= frame rate while visible and
  <= 1/s when all are hidden; in initialized ghostty-next, `rg -n 'dispatch_async|queue.getMain'
  src/renderer/metal/IOSurfaceLayer.zig` = 0.
- DC7r idle render (owned by p03): bench_idle.py --fresh with 10 Chromium tabs, one focused terminal with a
  blinking cursor, 60 s: render-attributed wakeups (display links, VSyncHub, Ghostty renderer, CA loops) = 0;
  render-idle-damage.py damage rects/s = 0; Ghostty frames over the window = 0.
- DC7j idle total (joint with the F2 pump program): app + daemon wakeups <= 1/s, main <= 0.5/s.
- DC8a pages are layers (72 h): `cef-layer-verify.py --checks hosted` passes with no tunable set;
  `debug.cef` tracker.hosted_pages = visible pages; a page whose window is never ordered in still produces frames.
- DC8b pages are views (Track B, after task 045): `debug.layers` page windows ordered in = 0;
  DividerMouseCatchers.panelUpdates = 0 over pane-perf-terminal.py --browser;
  `rg -c 'cmuxClipPath|cmuxOcclusionRects|browserChildWindowPagesNeedUpdate' Packages/macOS/CmuxNext/Sources
  --glob '!**/ChildWindowPageFallback.swift'` = 0; check-ime-input.py passes on a hosted page.
- DC9 resize never blocks main: cef-resize-sync-bench.py (hosting on, fence path): main-thread wait per commit
  p99 = 0.0 ms; page frame at the new size within 2 display frames p95; light and STRESS; same result on the new
  pin with hosting off (no post-commit wait).
- DC10 switch with Chromium: cef-layer-ab.py switch and tabs (STRESS): input to commit p95 < 8.3 ms,
  show.again true, longest frame <= 8.33 ms; switch-in to a recently hidden workspace makes 0
  `viewDidMoveToWindow` calls.
- DC11 invalidation discipline: `rg -n 'layoutSubtreeIfNeeded|displayIfNeeded|\.display\(\)|CATransaction\.flush'
  Packages/macOS/CmuxNext/Sources` hits without `// sync-layout:` on the line or the line above = 0; MQ-redraw-policy
  comm list empty; guardrails.py --list shows `sync-layout`; MQ-shadow-path, MQ-tracking-areas and MQ-draw lists
  contain only annotated files.
- DC12 hidden is free (render side): after switching away from a STRESS workspace and the grace, IOSurface and
  backing bytes held by hidden workspaces = 0 except frames locked or kept by HiddenFrameLRU; infinite CA
  animations attached in hidden or occluded windows = 0; hidden app web pages run 0 animations and 0 rAF callbacks.
- DC13 no per-frame window-server calls: during DC2 springs, hover-card fades and in-window drags, RenderStats
  NSWindow setFrame/alphaValue calls from cmux = 0 (window zoom: the frame steps stay AppKit's, grids per
  terminal = 1); GlassBackdropFeed evaluate calls <= 2 per page per spring.
- DC14 latency field data: perf-signposts.py reports `action.presented_estimate` p50/p95/p99/max for every action
  in the every-action sweep, Release, light and STRESS, with its p95 error against motion-hitches/window_record
  <= 1 frame; `motion.late_commits` = 0 over the DC2 springs.
- DC15 Tart: `scripts/cmux-next/os-matrix.sh --build JOB --os 14,15` launches, splits with `motion.renderServer`
  on, and shows a hosted Chromium page, with no crash (behavior only).
- DC16 window live resize: window-live-resize-bench.py, STRESS, Chromium selected: main per resize event p99
  <= 4 ms, 0 model reconciles per event.

## 6. Machine queues

Each hit (or each file, or each package where stated) is one task or part of one. A queue is done when its query
returns 0 hits or only annotated hits.

- MQ-springs (files): `rg -l 'SpringValue|AnimatedFrame|advanceUnsettled\(|\.advance\(dt' Packages/macOS/CmuxNext/Sources
  --glob '!**/CmuxNextDesign/Motion/**' --glob '!**/CmuxNextDesignTokens/**' --glob '!**/MotionParityCorpus.swift'`:
  18 files (Layout 14, Sidebar 1, Bridge 1, App 1, Canvas 1). Remaining gesture-follow uses say `// input-driven:`.
  Tasks 019-033, 106.
- MQ-appkit-frame-animators: `rg -n 'Motion\.animator\(|animator\(\)\.(frame|setFrame|setBoundsOrigin)'
  Packages/macOS/CmuxNext/Sources` plus `rg -n 'Motion\.[a-zA-Z]+\.animate\(' Packages/macOS/CmuxNext/Sources`
  (36). Tasks 100-104.
- MQ-frameclients: `rg -n 'FrameClient\(owner:' Packages/macOS/CmuxNext/Sources`: 24 hits; every hit DEBUG-only or
  marked `// input-driven:` / `// frame-client: <why>`. Task 107.
- MQ-displaylinks: `rg -n 'displayLink\(target:|CADisplayLink\(|CVDisplayLink' Packages/macOS/CmuxNext/Sources`
  plus (initialized) `rg -n 'createWithActiveCGDisplays|DisplayLink' ghostty-next/src/renderer/generic.zig`.
  Tasks 010, 014, 082, 083.
- MQ-sync-layout (per package one task): `rg -n 'layoutSubtreeIfNeeded|displayIfNeeded|\.display\(\)|CATransaction\.flush'
  Packages/macOS/CmuxNext/Sources`: 80 hits (App 22, Design 13 + flush, Browser 10, Sidebar 6, Palette 4,
  Home 4, others). Tasks 066-069.
- MQ-damage-owners (generated): the owner table from render-idle-damage.py and motion-main-work.py counting
  passes; each owner with damage > 0 at idle, or frame sets/layouts > 0 in motion frames 2..n, is one task, red
  count at base, green after. Inside each owner, every `needsLayout = true|needsDisplay = true` is guarded or
  annotated; `render-done-checks.py --invalidate` flags hits whose line or previous line has no `!= oldValue`,
  `guard ... !=`, `if ... !=` or `// invalidate:`. Tasks 062-065. The blanket 445-site rewrite is out of scope.
- MQ-redraw-policy: `comm -23 <(rg -l 'override (public |open )?func updateLayer' Packages/macOS/CmuxNext/Sources | sort)
  <(rg -l 'layerContentsRedrawPolicy' Packages/macOS/CmuxNext/Sources | sort)`: 59 files. Tasks 060-061.
- MQ-frame-observers: `rg -n 'frameDidChangeNotification|boundsDidChangeNotification|postsFrameChangedNotifications'
  Packages/macOS/CmuxNext/Sources`: 22 hits in 9 files. Tasks 037-039, 110.
- MQ-loops: `rg -n 'repeatCount = \.infinity' Packages/macOS/CmuxNext/Sources`: 10 hits. Tasks 013, 070.
- MQ-child-window-pages: `rg -n 'cmuxClipPath|cmuxOcclusionRects|browserChildWindowPagesNeedUpdate|postGeometryChange|cutouts'
  Packages/macOS/CmuxNext/Sources` outside ChildWindowPageFallback.swift, plus `rg -n 'addChildWindow'` (27 hits in
  21 files), each classified "page ordering (delete)" or "out-of-window popup (keep)". Tasks 051-053, 056.
- MQ-window-per-frame: `rg -n '(window|panel|Window|Panel)\??\.alphaValue = |self\.alphaValue = ' Packages/macOS/CmuxNext/Sources`
  (13), plus `rg -n '(panel|window|bubble)\??\.animator\(\)\.(alphaValue|setFrame)|animator\(\)\.setFrame'`
  (7) and drag-ghost `setFrameOrigin` per event. Tasks 034, 035, 105, 118.
- MQ-pane-autolayout: `rg -l 'translatesAutoresizingMaskIntoConstraints = false'` in CmuxNextLayout, CmuxNextTabs,
  CmuxNextTerminal, CmuxNextBrowser/UI, CmuxNextBrowser/CEF (34 files) and CmuxNextApp PaneContentView*,
  Screens/, WindowRootView, TitlebarView, EmptyWorkspaceView. Tasks 071-073, 111.
- MQ-ghostty-main-hops: (initialized) `rg -n 'dispatch_async|queue.getMain|isMainThread' ghostty-next/src/renderer`
  and `rg -n 'layer\?\.contents|presentedFrame' Packages/macOS/CmuxNext/Sources/CmuxNextTerminal`. Tasks 080, 081,
  084, 093, 119.
- MQ-producer-main-hops: `rg -n 'contents = surface' Packages/macOS/CmuxNext/Sources` outside CmuxNextTerminal: 3.
  Task 114.
- MQ-labels: `rg -c 'ChromeLabel\(' Packages/macOS/CmuxNext/Sources`: 136 sites, one cache. Task 075.
- MQ-shadow-path: `comm -23 <(rg -l shadowOpacity Packages/macOS/CmuxNext/Sources | sort) <(rg -l 'shadowPath|shadow: alpha-derived'
  Packages/macOS/CmuxNext/Sources | sort)`: 11 files. Task 108.
- MQ-tracking-areas: `comm -12 <(rg -l 'override (public |open )?func updateTrackingAreas' Packages/macOS/CmuxNext/Sources | sort)
  <(rg -l inVisibleRect Packages/macOS/CmuxNext/Sources | sort)`: 39 files. Task 109.
- MQ-draw: `rg -n 'override (public |open )?func draw\(_ ' Packages/macOS/CmuxNext/Sources`: 23 hits. Task 112.
- MQ-occlusion: `rg -l 'occlusionState|didChangeOcclusionStateNotification' Packages/macOS/CmuxNext/Sources`:
  27 files. Task 113.
- MQ-image-decode: `rg -n 'NSImage\(data:|NSImage\(contentsOf' Packages/macOS/CmuxNext/Sources`: 19 hits. Task 121.
- MQ-web-loops: `rg -n 'infinite' webviews/src` (26) and `rg -n 'requestAnimationFrame\(' webviews/src` (98).
  Task 120.

## 7. Risks

1. F4 decision (see "Recorded decision"). Mitigation: the tunable, the decision record and the capture video
   before task 022c flips the default; `browserResize.springPageResize = perFrame` stays for comparison.
2. AppKit vs explicit layer animations: AppKit can drop an animation when it re-sets a frame or rebuilds the
   layer. Spike task 016 picks the motion container layer and tests survival across layout, ancestor setFrame,
   display moves, full screen and wantsLayer changes.
3. Sublayer layout does not follow animated bounds (CA applies autoresizing at commit). Task 029 animates each
   dependent sublayer; DC4 checks it.
4. Hit testing mid-spring: drawn and NSView geometry differ for up to 240 ms. Task 098 hit-tests through the
   presentation tree; the old design's "Chrome does the same" claim was wrong (Chrome's bounds animate on main).
5. Render-server cost moves off main: 12 masked panes plus CALayerHosts can hitch the render server. DC3 measures
   it with xctrace; task 016 records the numbers first.
6. Ghostty off main: the rejected option (renderer CATransaction into the main tree) causes lock contention and
   teardown races. Spike task 017 decides; the single-writer rule and the frame sequence prevent stale frames.
7. CEF fork: about 1.6 h cold and 5-10 min incremental per build; each API bump serializes app tasks; a
   user-facing pin needs an R2 upload, which needs Lawrence (perf-lead F2). See the hour-0 decision below.
8. Pin bump re-adds the 50 ms post-commit wait unless the new fork skips `Synchronize()` for a 0 deadline or keeps
   AsyncLiveResize. Task 041 acceptance blocks that.
9. A page window that never orders in reads as occluded to Chromium (WasOccluded, compositor suspended). Task 058
   takes visibility from the embedder; DC8a checks frames still come.
10. Track B (RenderWidgetHostViewCocoa in CEFHostView) is a Chromium/CEF patch with real risk (views::Widget
    expectations, focus, popups anchored to the view's window). If it misses the 72 h, Track A ships alone
    (hosting on, transparent input window), and the deletions 051-053 wait.
11. SPI (CALayerHost, CAContext, fence ports) can change in a macOS update. The page-window fallback stays in one
    file behind the hosting-refused state.
12. Invalidation work touches many sites; a missed invalidation is stale paint that tests rarely catch. Only
    measured owners are edited, each with capture stills and the sidebar/Home e2e.
13. `.onSetNeedsDisplay` stretches backing stores during bounds springs; tasks 060/061 require stretch-safe contents.
14. Measurement: fleet minis have no lit display; timing uses `--vdisplay=120`, xctrace and a separate-process
    capture. VM timing is not perf evidence.
15. Overlap: F2 helper (remote_cocoa form, pump), threading program (VSyncHub QoS), typing (task 074, PL-typing),
    PL-switch (task 096), no-swiftui. Tell owners before editing.
16. 72 h fan-out: R2 tasks share ScreenContentView+Motion.swift. Task 019's seam puts each kind in its own file;
    only registration lines touch the shared file.

Hour-0 operator decision (one item, flagged in the program report): upload the cmux.33+ fork artifacts (arm64 and
x86_64) to R2 so the API >= 27 pin can reach Nightly, or land R3 behind a dev-artifact pin and state that DC8a,
DC9 and DC10 were shown on dev artifacts only.

## 8. Task table

Size: S <= 150 changed lines, M <= 400, L > 400 (split before start if possible). "Red first" (rule 9) applies to
every task that changes behavior or performance and is not repeated per row.

### Summary

| ID | Title | Size | Depends on | Queue |
| --- | --- | --- | --- | --- |
| 001 | RenderStats (armed-only swizzles, atomic counters) | M | - | none |
| 002 | motion-main-work.py counting passes | M | 001 | none |
| 003 | render-idle-damage.py and debug.damage | S | 001 | MQ-damage-owners |
| 004 | Release late-commit and presented-estimate signposts | M | 010, 012, 007 | none |
| 005 | render-done-checks.py (manual lane) | S | - | all |
| 006 | rendering-DESIGN.md and PATTERNS rows | S | - | none |
| 007 | motion-hitches.py (xctrace, off-main timing) | M | - | none |
| 010 | DisplayClock: one link per display | M | - | MQ-displaylinks |
| 011 | Screen change moves the scheduler | S | 010 | none |
| 012 | FrameTick BeginFrame args | S | 010 | none |
| 013 | FrameRateDecider | S | 010 | MQ-loops |
| 014 | VSyncHub owns the link; main fan-out | M | 010 | MQ-displaylinks |
| 015 | MainFrameBudget deadline | S | 012 | none |
| 016 | Spike: render-server springs on AppKit hosts | M | - | none |
| 017 | Spike: Ghostty off-main present form | M | - | none |
| 019 | MotionBackend seam and motion.renderServer | M | - | MQ-springs |
| 020 | RenderSpring (additive only) | M | - | MQ-springs |
| 021 | PaneMotionPlan (with sublayer rest frames) | M | - | MQ-springs |
| 022a | Split on the render server | M | 016, 019, 020, 021, 001 | MQ-springs |
| 022b | Close and camera shift on the render server | M | 022a | MQ-springs |
| 022c | Default flip and CPU path removal | M | 022b, 023-033, 036, 098, 106, 007 | MQ-springs |
| 023 | Strip clip as layer structure | M | 022a | MQ-springs |
| 024 | Dividers as layers | M | 022a | MQ-springs |
| 025 | Camera springs | L | 022a | MQ-springs |
| 026 | Strip pan O(1) on a motion container | M | 025 | MQ-springs |
| 027 | Zoom | S | 022a | MQ-springs |
| 028 | PaneArrival | S | 022a | MQ-springs |
| 029 | Pane chrome sublayer springs and overlays | M | 020, 021, 022a | MQ-frameclients |
| 030 | Screen switch springs | S | 019, 020 | MQ-springs |
| 031 | Canvas camera | S | 019, 020 | MQ-springs |
| 032 | DropHighlightView | S | 020 | MQ-springs |
| 033 | Sidebar card slot | M | 020 | MQ-springs |
| 034 | Window close fade | S | 020 | MQ-window-per-frame |
| 035 | Tab drag ghost | M | 020 | MQ-window-per-frame |
| 036 | Pages resize once in one fence; hosting-off fallback | M | 022a, 043 | none |
| 037 | GlassBackdropFeed without per-frame JS | S | 022a | MQ-frame-observers |
| 038 | Design frame observers | S | - | MQ-frame-observers |
| 039 | Sidebar, Terminal, Palette, App observers | S | - | MQ-frame-observers |
| 041 | CEF pin API >= 27 without a commit wait | S | - | none |
| 042 | Fork fence-port resize API | L | 041 | none |
| 043 | App fence transactions | M | 042 | none |
| 044 | Fork: RenderWidgetHostViewCocoa in the embedder view | L | 041, 058 | none |
| 045 | App adopts the attached Chromium view | M | 044 | none |
| 046 | Chromium native UI on the attached view (select, menus, autofill, IME, AX, drag) | M | 045 | none |
| 050 | Layer hosting on by default (Track A) | S | 041, 043, 058 | none |
| 051 | Delete divider catcher panels | M | 045 | MQ-child-window-pages |
| 052 | Overlays in an in-window top layer | L | 045 | MQ-child-window-pages |
| 053 | Child-window path into one fallback file | M | 045 | MQ-child-window-pages |
| 054 | Show/hide in the switch's transaction | M | 050, 099 | none |
| 055 | Hidden page volatile snapshot | M | 054 | none |
| 056 | DevTools and popups hosted | L | 050 | MQ-child-window-pages |
| 058 | Fork: visibility from the embedder | M | 041 | none |
| 060 | Redraw policy: Sidebar (28) | S | 001 | MQ-redraw-policy |
| 061 | Redraw policy: the rest (31) | S | 001 | MQ-redraw-policy |
| 062 | Invalidation: measured Sidebar owners | M | 003 | MQ-damage-owners |
| 063 | Invalidation: measured Home owners | S | 003 | MQ-damage-owners |
| 064 | Invalidation: measured Design and App owners | M | 003 | MQ-damage-owners |
| 065 | Invalidation: measured remaining owners | M | 003 | MQ-damage-owners |
| 066 | Guardrail sync-layout | S | - | MQ-sync-layout |
| 067 | Sync layouts: App | M | 066 | MQ-sync-layout |
| 068 | Sync layouts: Design and the popup flush | S | 066 | MQ-sync-layout |
| 069 | Sync layouts: the rest | M | 066 | MQ-sync-layout |
| 070 | Loops stop when hidden or occluded | M | 001, 097 | MQ-loops |
| 071 | No Auto Layout: browser toolbar and omnibar | L | - | MQ-pane-autolayout |
| 072 | No Auto Layout: browser status views | L | - | MQ-pane-autolayout |
| 073 | No Auto Layout: terminal badges, hover card | M | - | MQ-pane-autolayout |
| 074 | Home composer chrome as layers | L | 001 | none |
| 075 | Shared GlyphMask cache | S | - | MQ-labels |
| 079 | Ghostty integrator lane | S | - | none |
| 080 | ghostty-next: present off main (spike form) | M | 017 | MQ-ghostty-main-hops |
| 081 | cmux adopts renderer-owned frames | M | 080 | MQ-ghostty-main-hops |
| 082 | ghostty-next: external vsync | M | - | MQ-displaylinks |
| 083 | cmux drives surfaces from VSyncHub | M | 014, 082 | MQ-displaylinks |
| 084 | Pre-commit present never waits; frame sequence | M | 080 | MQ-ghostty-main-hops |
| 085 | Grid/snapshot/status off the main actor | L | - | none |
| 086 | Manual-IO surfaces: no IO thread | M | - | none |
| 087 | Shared atlas and command queue | L | - | none |
| 088 | Renderer QoS by visibility | S | - | none |
| 089 | No frame when nothing changed | S | - | none |
| 090 | ghostty-next: external cursor with cell image | M | - | none |
| 091 | TerminalCursorLayer | M | 090, 070 | none |
| 092 | Buffer-age partial redraw (purge-aware) | L | 089 | none |
| 093 | Terminal frame ownership: probes, counters, hide/show API | M | 080 | MQ-ghostty-main-hops |
| 096 | Hidden workspace: hide plus evict, detach by measurement | M | 109, 099 | none |
| 097 | WindowOcclusionFamily with the same-size check | M | 010 | none |
| 098 | Hit testing through the presentation tree | M | 022a | none |
| 099 | HiddenFrameLRU | M | - | none |
| 100 | Sidebar slide on the render server | L | 001, 020, 019 | MQ-appkit-frame-animators |
| 101 | Titlebar band reveal | S | 020 | MQ-appkit-frame-animators |
| 102 | Toggle Omnibar without per-frame page resizes | S | 020 | MQ-appkit-frame-animators |
| 103 | Sidebar frame animators to SidebarDragSpring | M | 001 | MQ-appkit-frame-animators |
| 104 | MotionGate.animate: prove or remove per-frame writes | M | 001, 020 | MQ-appkit-frame-animators |
| 105 | NSWindow/NSPanel animators | M | 001 | MQ-window-per-frame |
| 106 | ScreenContentView state and visibility from the plan | M | 022a | MQ-springs |
| 107 | Classify every FrameClient | S | 013, 005 | MQ-frameclients |
| 108 | shadowPath on shadowed layers | S | - | MQ-shadow-path |
| 109 | .inVisibleRect tracking areas added once | M | 001 | MQ-tracking-areas |
| 110 | Responsive scrolling | M | 039 | none |
| 111 | No Auto Layout: pane content and window root | L | 100 | MQ-pane-autolayout |
| 112 | draw(_:) overrides to layer properties | M | 001 | MQ-draw |
| 113 | Occlusion readers onto WindowOcclusionFamily | M | 097 | MQ-occlusion |
| 114 | Phone and RemoteView producers off main | S | - | MQ-producer-main-hops |
| 115 | Window live resize bench and O(changed) path | M | 001 | none |
| 116 | CEF pump slices respect the frame deadline | M | 012, 015, 041 | none |
| 117 | Low Power and thermal frame-rate caps | S | 013, 070 | none |
| 118 | Link and workspace drag ghosts in-window | S | 035 | MQ-window-per-frame |
| 119 | Ghostty wakeup_cb ticks frame-coalesced | S | - | MQ-ghostty-main-hops |
| 120 | App web pages stop loops when hidden | M | 003 | MQ-web-loops |
| 121 | Off-main image decode | M | - | MQ-image-decode |

### Review disposition (fixer)

- Accepted as new tasks: 007, 016, 017 (from the Ghostty problem in reviews 2 and 3), 019, 058, 079, 093, 098, 099,
  100-121. Review 2's 040 (FrameClient classification) is merged into 107. Review 3's 020b (sublayer parity) is
  merged into 029 and 021. Review 1's 113 and review 3's 097b are merged into 113 (all 27 readers, plus the same-size
  check in 097). Review 3's 044b/045b replace the design's 044 and 045.
- Dropped with reason:
  - design 044-049 cmux-side input forwarding: Chrome keeps input and pixels in one NSView (rule above); Track B
    gets IME, cursor, drag and AX from Chromium; the helper design estimates the same fork work at 3-4 weeks.
    The helper's forwarding stays with F2.
  - design 057 (merge CEFHostedPageView and ChromiumHostPageView): with Track B, in-process pages no longer use
    CEFHostedPageView except as fallback; the helper view moves to the remote_cocoa bridge, which F2 owns.
  - review 3's "enable OnlyUseWindowResizeHelperOnResize at hour 0": below API 27 cmux already adds
    AsyncLiveResize, which skips `Synchronize()` entirely (`CEFSwitches.swift:63-68`, checked), so both waits do not
    run today. The real risk is the API 27 pin dropping that switch; task 041 now blocks it.
  - design 062-065 blanket 445-site rewrite: replaced by measured owners (review 2), because a diff reviewer cannot
    check "unguarded" consistently and the gain is not measured.
- Problems fixed in place: 022 split into a/b/c behind the seam; 023/053 fallback in one file and DC8 counts outside
  it; 026 motion container plus hitTest offset; 036 hosting-off fallback, one fence, and decision record; 050
  dependencies; 004 metric renamed and moved off main; 001 armed-only; 005 manual lane and submodule check; 014 one
  link per display with a measured fallback; 015 meter source named; 020 additive only; 060/061 stretch rule; 080/084
  single writer and frame sequence; 090/091 cursor-cell contents; 092 purge rule; 096 hide-not-detach; 097 same-size
  check; 054/055 global LRU; DC2 scenarios extended; DC6 adds GhosttyRuntime.tick; DC7 split; DC1 rewritten.

### Task details

#### p03-rendering-001 RenderStats: per-frame counters (armed only)
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Diagnostics/RenderStats.swift` (new),
  `.../CmuxNextDesign/Diagnostics/LayoutPassGuard.swift`, `.../CmuxNextApp/Control/DebugFrameProbe.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextDesignTests/RenderStatsTests.swift` (new).
- Change: swizzles like LayoutPassGuard, compiled only under `DEBUG || CMUX_BENCH_HOOKS`, installed when
  `debug.frames` or `debug.damage` is armed and removed when disarmed: `-[NSView setFrameSize:]`,
  `setFrameOrigin:`, `updateLayer`, `drawRect:`, `addTrackingArea:`, `-[CALayer setContents:]`,
  `-[NSWindow setFrame:display:]`, `setAlphaValue:`. Counters are atomic (or per thread, merged on read), per
  display frame and per owner class, plus damage area for updateLayer and draw, plus infinite-repeat animations in
  hidden views. `debug.frames` returns frame_sets, layouts, damage_rects, damage_area, contents_sets, window_calls,
  tracking_area_adds. An equal-frame set counts 0.
- Acceptance: no swizzle reachable in Release; with RenderStats disarmed the swizzled IMP is the original (test);
  3 frame sets in one turn count 3; a no-op set counts 0; a contents set from a background thread counts without a
  data race (TSan test); existing debug.frames keys unchanged.
- Test phase: `cmux-ci run --class isolated` swift test --filter RenderStatsTests (macOS 26, 27), plus a TSan run.
- Size M. Depends: none. Queue: none.

#### p03-rendering-002 motion-main-work.py: counting passes
- Files: `scripts/cmux-next/motion-main-work.py` (new), `scripts/cmux-next/perf-hot-benches.json`.
- Change: launch via bench_launch.py; STRESS via perf-stress-session.py 4x3 with Chromium selected. Scenarios:
  Cmd-D, Cmd-Shift-D, Cmd-W, zoom, New Column, close-last-column, workspace switch, strip pan, sidebar toggle,
  Toggle Omnibar, band reveal, window zoom, hover card, sidebar reorder, scroll-to-row. 3 rounds each at
  `--vdisplay=120`. Arms RenderStats for counting passes only and reports frame_sets, layouts, window_calls,
  tracking_area_adds for frames 2..n, and updateVisibility per spring. Timing comes from task 007, not this script.
  Map motion-frame in perf-hot-benches.json to both scripts. Not a CI job.
- Acceptance: records host, macOS, refresh rate; checks Chromium pages are real (`debug.cef` unavailable=false,
  P12); exits non-zero on a wrong session shape; never reports ms from an armed pass.
- Test phase: aws-m4pro-5 (26) and aws-m4pro-1 (27) at base and head; baseline table in perf-lead.md section 5.
- Size M. Depends: 001.

#### p03-rendering-003 render-idle-damage.py and debug.damage
- Files: `scripts/cmux-next/render-idle-damage.py` (new), `.../CmuxNextApp/Control/AppControl.swift`,
  `.../CmuxNextApp/Control/DebugDamage.swift` (new).
- Change: `debug.damage start|stop` sums RenderStats damage and contents_sets per owner, plus Ghostty frames from
  `debug.terminal_display`. The bench: STRESS, 10 Chromium tabs, one focused blinking terminal, 60 s idle; also a
  motion pass over the DC2 scenarios. Output: per-owner table, JSON, which is the MQ-damage-owners queue.
- Acceptance: reports unavailable in Release; prints owners with damage > 0 sorted; JSON schema documented in the
  script header.
- Test phase: fleet run at base; the list seeds tasks 062-065 and 120.
- Size S. Depends: 001. Queue: MQ-damage-owners (generator).

#### p03-rendering-004 Release late-commit and presented-estimate signposts
- Files: `.../CmuxNextSignposts/CmuxNextSignposts.swift`, `.../CmuxNextDesign/Motion/MotionInFlight.swift`,
  `.../CmuxNextActions/ActionBudgetMonitor.swift`, `scripts/cmux-next/perf-signposts.py`.
- Change: in Release, record what the app controls. (1) `motion.late_commits`: for each main CA commit while
  MotionInFlight reports an animation, compare the commit time against the current tick's targetTimestamp (read
  from DisplayClock's last tick, no new link). (2) `action.presented_estimate`: the targetTimestamp of the first
  tick after the action's commit. (3) Where a true presented time exists (Ghostty presentedTime after 080), emit
  `action.presented` too. perf-signposts.py folds them into distributions and reports the estimate's error against
  motion-hitches.py.
- Acceptance: the counter starts no display link and no FrameClient (test: no link armed by a motion with the
  counter on); a fake commit after the deadline counts 1 late commit; no record with no animation; perf-signposts.py
  test covers the new rows.
- Test phase: every-action-sweep.py shard 1 on Release: distributions; estimate error p95 <= 1 frame.
- Size M. Depends: 010, 012, 007.

#### p03-rendering-005 render-done-checks.py
- Files: `scripts/cmux-next/render-done-checks.py` (new), `tests/test_render_done_checks.py` (new),
  `tests/test-execution.toml`.
- Change: runs DC1, DC8 (rg parts), DC11 and every MQ count as rg/comm queries; `--invalidate` heuristic (MQ-damage-
  owners); `--frameclients` marker check; fails if ghostty-next is not initialized at the pinned gitlink; reads bench
  JSON if passed (`--motion`, `--hitches`, `--idle`, `--typing`, `--cef`). Prints query, count, threshold.
- Acceptance: unit test against a fixture tree; registered with `lane = "manual"` and the reason "fleet and local
  tool; Lawrence 2026-10-23 no new CI tests"; no `.github` reference.
- Test phase: run at branch tip at the start and end of the 72 h.
- Size S. Depends: none. Queue: all.

#### p03-rendering-006 rendering-DESIGN.md and PATTERNS rows
- Files: `plans/cmux-next/rendering-DESIGN.md` (new), `plans/cmux-next/PATTERNS.md`, `plans/cmux-next/perf-lead.md`,
  `plans/cmux-next/threading-model.md`.
- Change: R1-R7, the Chrome mapping with file citations, the reasons cmux differs (bounds animated on the render
  server; one CAContext per page while cmux chrome is AppKit, with per-page GPU memory and BeginFrame cost from
  bench_memory.py and bench_idle.py), done checks and queues. PATTERNS P6/P7/P8 name DisplayClock, RenderSpring,
  PaneMotionPlan, WindowOcclusionFamily, HiddenFrameLRU. threading-model.md lists the VSyncHub thread and the
  renderer QoS table. perf-lead F1/F4 rows link here.
- Acceptance: docs only; each pattern row names one file; STE and STYLE.md.
- Size S.

#### p03-rendering-007 motion-hitches.py: off-main motion timing
- Files: `scripts/cmux-next/motion-hitches.py` (new), `scripts/cmux-next/motion-main-work.py`,
  `plans/cmux-next/perf-lead.md`.
- Change: record `xctrace --template 'Animation Hitches'` and a Time Profiler of main over each spring at
  `--vdisplay=120`; parse hitch and commit tables; second source: ScreenCaptureKit frame timestamps from a separate
  recorder process. Main ms per spring frame from samples. No `debug.window_record` or `debug.frames` during timed
  passes.
- Acceptance: checks `debug.wakeups` live links = 0 at idle before and after; prints hitch count and duration
  p50/p95/p99/max per scenario, light and STRESS, with host, OS, refresh rate.
- Test phase: aws-m4pro-5 (26) and aws-m4pro-1 (27) at base: the DC2t/DC3 baseline.
- Size M.

#### p03-rendering-010 DisplayClock: one link per display
- Files: `.../CmuxNextWakeups/DisplayClock.swift` (new), `.../CmuxNextWakeups/FrameScheduler.swift`,
  `.../CmuxNextWakeups/MainWorkScheduler.swift`, `scripts/cmux-next/check-concurrency.sh`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextWakeupsTests/DisplayClockTests.swift` (new).
- Change: DisplayClock keyed by CGDirectDisplayID, built in AppServices (P1), owns the only link creation through
  an injected link factory, runs while any subscriber is armed. `FrameScheduler.makeLink` becomes `subscribe(to:)`.
  Delivery order per tick: budget holder's frame-locked clients, window schedulers, budgeted classes. One stall timer
  per display. check-concurrency.sh allows link creation only in DisplayClock.swift and VSyncHub.swift.
- Acceptance: `rg -n 'displayLink\(target:' Packages/macOS/CmuxNext/Sources` hits only DisplayClock.swift; fake
  factory test: 2 window schedulers, app and budgeted on one display make linksMade = 1; link dropped when the last
  client disarms; FrameScheduler tests pass unchanged.
- Test phase: swift test --filter 'DisplayClockTests|FrameSchedulerTests|MainWorkSchedulerTests'; bench_idle.py: 0
  links at idle.
- Size M. Queue: MQ-displaylinks.

#### p03-rendering-011 Screen change moves the scheduler
- Files: `.../CmuxNextWakeups/FrameScheduler.swift`, `.../CmuxNextWakeups/WindowScreenFamily.swift` (new),
  `.../Tests/CmuxNextWakeupsTests/DisplayClockTests.swift`.
- Change: one adapter per window observes `NSWindow.didChangeScreenNotification` (P3) and re-subscribes.
- Acceptance: move between fake 60 and 120 Hz clocks mid-animation: ticks only from the new clock, no gap > 1
  interval, no double tick; the adapter is the only observer of that notification in the package.
- Test phase: DisplayClockTests; fleet host with two virtual displays, window moved during Cmd-D.
- Size S. Depends: 010.

#### p03-rendering-012 FrameTick BeginFrame args
- Files: `.../CmuxNextWakeups/FrameClient.swift`, `.../CmuxNextWakeups/DisplayClock.swift`,
  `.../CmuxNextDesign/Motion/MotionClock.swift`.
- Change: FrameTick gains targetTimestamp and sequence. Samplers of presented values evaluate at targetTimestamp.
- Acceptance: additive struct change; readers tested with a fake tick; no `CACurrentMediaTime()` for a presented
  value where a tick is available (diff grep).
- Test phase: swift test --filter 'FrameScheduler|MotionClock'.
- Size S. Depends: 010.

#### p03-rendering-013 FrameRateDecider
- Files: `.../CmuxNextWakeups/FrameClient.swift`, `.../CmuxNextWakeups/DisplayClock.swift`,
  `.../CmuxNextDesign/Motion/Motion+AppKit.swift`, `.../CmuxNextDesign/NightSky/NightSkyView.swift`.
- Change: FrameClient declares `.motion` (80-120), `.ui` (60), `.ambient` (30), `.slow(n)`; the link's
  preferredFrameRateRange is the highest armed class; looping CA animations set `preferredFrameRateRange`.
- Acceptance: only `.ambient` gives 30; adding `.motion` gives 120; no timing token touched.
- Test phase: bench_power.py with a spinner visible: link rate 30 Hz, package power lower than base.
- Size S. Depends: 010. Queue: MQ-loops.

#### p03-rendering-014 VSyncHub owns the link; main fan-out
- Files: `.../CmuxNextWakeups/VSyncHub.swift` (new), `.../CmuxNextWakeups/DisplayClock.swift`,
  `.../Tests/CmuxNextWakeupsTests/VSyncHubTests.swift` (new), `plans/cmux-next/threading-model.md`.
- Change: one thread per display, QoS userInteractive (`// qos-allow:` a frame waits on it), its own run loop,
  holding that display's only link (from DisplayClock's factory). Off-main subscribers register a Sendable callback
  (targetTimestamp ns, sequence). DisplayClock becomes a hub subscriber that posts one coalesced tick to main (at most
  one pending, Chrome's post-to-register-thread). Producers arm on dirty content and disarm after one empty tick.
  The test measures the hop: if main tick latency p99 rises >= 0.1 ms over a main link, the task keeps a main link
  plus the hub link and records the numbers in rendering-DESIGN.md (DC1 fallback).
- Acceptance: off-main callbacks never run on main; zero armed subscribers = no link and no wake (fake); one link per
  display with both main and off-main subscribers armed (or the recorded fallback); threading-model.md row names
  thread, QoS, may-block-on (nothing), bound.
- Test phase: VSyncHubTests; bench_idle.py unchanged; typing-frame-bench.py not worse.
- Size M. Depends: 010. Queue: MQ-displaylinks.

#### p03-rendering-015 MainFrameBudget deadline
- Files: `.../CmuxNextWakeups/MainFrameBudget.swift`, `.../CmuxNextWakeups/MainWorkScheduler.swift`,
  `.../Tests/CmuxNextWakeupsTests/MainFrameBudgetTests.swift`.
- Change: budgeted classes run until targetTimestamp minus p95 of the last 32 main CA commit plus layout durations
  (the existing `ca.commit` work in debug.motion plus LayoutPassGuard time, meter `MainCommitMeter`). Input preempts.
- Acceptance: fake clock, 3 ms history at 120 Hz: work stops 5.33 ms after the tick; no history: old fixed budget.
- Test phase: script-storm-bench.py light and STRESS: dropped frames <= base, key to frame p99 lower.
- Size S. Depends: 012.

#### p03-rendering-016 Spike: render-server springs on AppKit pane hosts
- Files: `Packages/macOS/CmuxNext/Tests/CmuxNextLayoutTests/RenderMotionSpikeTests.swift` (new),
  `plans/cmux-next/rendering-DESIGN.md`.
- Change: additive animations on the host backing layer and on a dedicated motion container layer; check survival
  mid-spring across AppKit layout, ancestor setFrame, display move, full screen, wantsLayer change; check that a
  CALayerHost and an IOSurface leaf clip correctly inside a masksToBounds + cornerRadius host; measure 12 animated
  masked panes with xctrace Animation Hitches. Record the chosen layer and the numbers.
- Acceptance: presented geometry asserted at 25/50/75 % after each disturbing event; doc records the choice.
- Test phase: `cmux-ci run --class isolated` on 26 and 27; Tart 14/15 behavior.
- Size M. Start hour 0.

#### p03-rendering-017 Spike: Ghostty off-main present form
- Files: `plans/cmux-next/rendering-DESIGN.md`, a ghostty-next spike branch (`ghostty-next/src/renderer/Metal.zig`,
  `src/renderer/metal/IOSurfaceLayer.zig`).
- Change: prototype (a) CAMetalLayer, `presentsWithTransaction = false`, present on the renderer thread, IOSurface
  pre-commit path for resize frames only; (b) per-renderer CAContext plus CALayerHost. Measure with 10 `yes`
  terminals: main turns, main commit time, hitches, contention (main thread time in CA locks), teardown safety.
- Acceptance: doc records the choice with numbers; the chosen form satisfies rule 5; teardown retains the layer
  until the renderer stops.
- Test phase: fleet, zig build test plus an app run on a dev pin.
- Size M. Start hour 0. Owner PL-ghostty.

#### p03-rendering-019 MotionBackend seam and Tunable motion.renderServer
- Files: `.../CmuxNextLayout/Motion/MotionBackend.swift` (new), `.../CmuxNextLayout/Views/ScreenContentView+Motion.swift`,
  `.../CmuxNextLayout/Core/LayoutTunables.swift`.
- Change: protocol with `cpuStep` (today's step/applyPresentation) and `renderServer` backends, one entry point per
  motion kind (split/close, zoom, arrival, camera, rows, areas, screens, canvas, drop highlight, sidebar slide).
  Tunable `motion.renderServer`, default off.
- Acceptance: tunable off = unchanged behavior (PaneMotionWorkTests pass); tasks 022a-033 edit a host's
  registration file only to register a kind: `ScreenContentView+Motion.swift` (split/close, zoom, arrival,
  camera, rows, areas, canvas) or `LayoutRootView+Motion.swift` (screens, drop highlight). The seam
  (`RenderMotionKind`, `RenderServerMotion<Host>`, `MotionBackends<Host>`) is in CmuxNextDesign, so task 100
  registers the sidebar slide on `SidebarContainerView` with its own begin site.
- Test phase: swift test --filter 'PaneMotion'.
- Size M. Start hour 0. Queue: MQ-springs.

#### p03-rendering-020 RenderSpring (additive only)
- Files: `.../CmuxNextDesign/Motion/RenderSpring.swift` (new), `.../CmuxNextDesign/Motion/Motion+AppKit.swift`,
  `.../Tests/CmuxNextDesignTests/RenderSpringParityTests.swift` (new).
- Change: `RenderSpring.animate(layer, keyPath:, to:, token:, gate:)` sets the model value and adds an additive
  CASpringAnimation (mass 1, stiffness/damping from SpringParameters) from (old - new) to 0. Retarget adds a delta
  spring with initialVelocity 0. Per-component key paths for release velocity (normalized per axis).
  `animateGroup(host:, sublayers:, plan:)` gives sublayers the same token and beginTime. Gate off: value in one frame,
  completion runs. Completion is a CATransaction completion block.
- Acceptance: parity <= 0.25 pt at 240 samples for every token (sampled through `presentation()`); perpendicular
  retarget finite-difference test continuous in value and velocity; no SpringValue or MotionPath call in the retarget
  path; check-motion.sh passes.
- Test phase: RenderSpringParityTests on 26 and 27; motion-parity.py.
- Size M. Queue: MQ-springs.

#### p03-rendering-021 PaneMotionPlan
- Files: `.../CmuxNextLayout/Motion/PaneMotionPlan.swift` (new),
  `.../Tests/CmuxNextLayoutTests/PaneMotionPlanTests.swift` (new).
- Change: pure Sendable value from previous and next ScreenGeometry: per changed pane from/to rect,
  appear/disappear, zoom rank, and rest frames of its chrome sublayers (ring, glow, dim, border, edge-anchored
  items); per changed divider from/to; camera from/to (strip, rows, areas); token per item. Unchanged panes absent.
  No presentation read (additive retarget needs none).
- Acceptance: tests for split right/down, close, zoom in/out, New Column at 30 panes, close of last column, retarget;
  an unmoved pane is absent; 30-pane build < 0.2 ms (Release measure test).
- Test phase: PaneMotionPlanTests.
- Size M. Queue: MQ-springs.

#### p03-rendering-022a Split on the render server (behind the seam)
- Files: `.../CmuxNextLayout/Views/ScreenContentView+RenderMotion.swift` (new), `.../CmuxNextLayout/Views/PaneHostView.swift`,
  `.../CmuxNextLayout/Views/SplitMotion.swift`, `.../CmuxNextLayout/Views/ScreenContentView+Motion.swift` (registration).
- Change: in the key's turn with `motion.renderServer` on: host.frame = rest and one layout per changed host;
  RenderSpring on the motion container layer (task 016) for position, bounds.size, opacity; isOnLayoutSpring and
  announceRest at start; landing completion clears isOnLayoutSpring, calls paneMotionDidSettle and userMotionEnded,
  syncs hover once. The perf-hot marker for this kind moves to the plan apply.
- Acceptance: runtime test (LayoutRootView with fake hosts): host frames = rest after the key's turn; presented rect at
  50 % between from and to; MotionClock 'layout' frames = 0; landing fires once; Reduce Motion lands in one frame;
  tunable off unchanged.
- Test phase: motion-main-work.py and motion-hitches.py Cmd-D light and STRESS, both tunable states; split-spring.sh
  --suite=pane-bench --vdisplay=120.
- Size M. Depends: 016, 019, 020, 021, 001. Owner PL-motion-core.

#### p03-rendering-022b Close and camera shift on the render server
- Files: `.../CmuxNextLayout/Views/ScreenContentView+RenderMotion.swift`, `.../CmuxNextLayout/Views/LayoutRootView.swift`.
- Change: Cmd-W and close-last-column use the plan; the camera rides the frame spring (Lawrence 2026-10-20);
  reportLeadingColumn in the landing completion.
- Acceptance: runtime tests for Cmd-W both axes and close-last-column: 0 per-frame steps, landing once.
- Test phase: motion-main-work.py close scenarios; split-no-flicker-e2e.py.
- Size M. Depends: 022a.

#### p03-rendering-022c Default flip and CPU path removal
- Files: `.../CmuxNextLayout/Core/LayoutTunables.swift`, `.../CmuxNextLayout/Views/ScreenContentView+Motion.swift`,
  `.../CmuxNextLayout/Views/DisplayLinkDriver.swift`, `plans/cmux-next/perf-lead.md`,
  `plans/cmux-next/cef-layer-hosting-DESIGN.md`.
- Change: after DC2, DC2t, DC3 and DC4 pass with the tunable on: record the F4 decision (section 3) with the
  measured reason and a capture video of Cmd-D and Cmd-W with a Chromium pane; set `motion.renderServer` default on;
  remove AnimatedFrame stepping for structural kinds from step(); DisplayLinkDriver starts only for gestures.
- Acceptance: the decision text and video link are in both docs in the same PR; MQ-springs count reaches 0 or
  annotated `// input-driven:`; the PR is risk:normal with the behavior behind the tunable (off restores cpuStep until
  the cpuStep code is deleted in a follow-up after one Nightly).
- Test phase: full DC2/DC3 set on 26 and 27; every-action sweep motion rows.
- Size M. Depends: 022b, 023-033, 036, 098, 106, 007.

#### p03-rendering-023 Strip clip as layer structure
- Files: `.../CmuxNextLayout/Views/ScreenContentView+Dock.swift`, `.../CmuxNextLayout/Views/StripClipInput.swift`,
  `.../CmuxNextLayout/Views/PaneHostView.swift`, `.../CmuxNextLayout/Views/ScreenContentView.swift`.
- Change: scrolling panes in a masksToBounds strip container; docks stack above in z order (opaque); clipToStrip at
  structural changes only. While any visible page is a child window, the cutouts path stays, moved into
  `CmuxNextBrowser/CEF/ChildWindowPageFallback.swift` behind the hosting state.
- Acceptance: stripClipsComputed constant across spring frames; dock over strip covered by z order (layer order
  snapshot); no per-frame mask layer.
- Test phase: motion-record.py panes with docks; dock-split-pane-e2e.py.
- Size M. Depends: 022a.

#### p03-rendering-024 Dividers as layers
- Files: `.../CmuxNextLayout/Views/ScreenDividers.swift`, `.../CmuxNextLayout/Views/DividerHandleView.swift`,
  `.../CmuxNextLayout/Views/ScreenContentView+RenderMotion.swift`.
- Change: divider frame = rest once; RenderSpring on its layer with the panes' token; refreshDividerHover,
  cursorClip, placedClips at apply and landing.
- Acceptance: 0 DividerHandleView frame sets between start and landing; hover at landing = fresh hit test.
- Test phase: motion-main-work.py; split-no-flicker-e2e.py.
- Size M. Depends: 022a.

#### p03-rendering-025 Camera springs
- Files: `.../CmuxNextLayout/Views/ScreenContentView+Rows.swift`, `+ScrollAreas.swift`, `+Scrolling.swift`,
  `.../CmuxNextLayout/Scroll/ColumnScrollState.swift`.
- Change: stepRows, stepAreas, scroll.advance become RenderSpring on strip/row/area container `bounds.origin`
  (camera token); scrollbar thumb is a sublayer spring with the same token.
- Acceptance: close-last-column: camera on the frame spring, MotionClock frames 0; no per-frame updateScrollbar.
- Test phase: bench-command-pan.py; motion-main-work.py.
- Size L (split rows/areas into a second PR if over 400 lines). Depends: 022a.

#### p03-rendering-026 Strip pan O(1) on a motion container
- Files: `.../CmuxNextLayout/Views/ScreenContentView+Motion.swift`, `.../CmuxNextLayout/Views/LayoutRootView+Scroll.swift`,
  `.../CmuxNextLayout/Views/ScreenContentView+Scrolling.swift`, `.../CmuxNextLayout/Views/LayoutRootView.swift`.
- Change: during the gesture, presentPan sets the motion container layer's `sublayerTransform` translation with
  actions disabled (not the NSView bounds, which would make AppKit recompute visibleRect, tracking areas and
  cursor rects for every descendant). LayoutRootView.hitTest and convert apply the live offset. NSView geometry
  commits once at gesture end or fling landing. Visibility updates only on a viewport-edge crossing. Fling =
  RenderSpring with release velocity. panTickTail ticks removed.
- Acceptance: 50 pan events: 0 host frame sets, 1 layer property set per event, 0 addTrackingArea calls; a click
  during the pan hits the pane under the pointer; ScrollClaim tests pass.
- Test phase: split-spring.sh --suite=command-pan --vdisplay=120: 0 hitches; pan main ms per event p99 <= 0.3.
- Size M. Depends: 025.

#### p03-rendering-027 Zoom
- Files: `.../CmuxNextLayout/Views/PaneZoomMotion.swift`, `.../CmuxNextLayout/Views/ScreenContentView+RenderMotion.swift`.
- Change: zooming pane zPosition above docks during the spring; zoom token; covered panes untouched;
  releaseCovered at landing.
- Acceptance: Cmd-Shift-Enter in/out: 0 per-frame steps; covered frames unchanged; stacking restored.
- Test phase: zoom-frames.py; motion-main-work.py zoom.
- Size S. Depends: 022a.

#### p03-rendering-028 PaneArrival
- Files: `.../CmuxNextLayout/Views/PaneArrival.swift`, `.../CmuxNextLayout/Views/ScreenContentView+Dock.swift`.
- Change: growing docks animate their dock container bounds; no per-frame PaneArrival.stripClip.
- Acceptance: `rg -n 'stripClip\(' Packages/macOS/CmuxNext/Sources/CmuxNextLayout` called only at plan apply; new dock
  column 0 steps per frame.
- Test phase: dock-split-pane-e2e.py; motion-record.py.
- Size S. Depends: 022a.

#### p03-rendering-029 Pane chrome sublayer springs and overlays
- Files: `.../CmuxNextLayout/Views/PaneOverlayView.swift`, `PaneOverlayView+Glow.swift`,
  `LayoutRootView+OverlaySync.swift`, `OverlayPlane.swift`,
  `.../Tests/CmuxNextLayoutTests/PaneSublayerParityTests.swift` (new).
- Change: per-pane ring, glow, dim and overlay layers become sublayers of the host's motion container; each gets
  its own RenderSpring from the plan's sublayer rest frames via `animateGroup` (no autoresizing during springs), or a
  9-slice ring (contentsCenter) with one bounds spring. overlayNeedsSync at apply and landing only. Cross-pane
  overlays (drop zones) stay in the plane.
- Acceptance: flushOverlaySync <= 2 per Cmd-D spring; parity test samples presentation() of host and each sublayer
  at 25/50/75 % of Cmd-D and Cmd-W: edges within 0.5 pt.
- Test phase: PaneSublayerParityTests on 26/27; motion-record.py focus/panes; capture stills at 0/25/50/100 % light
  and dark for terminal, Chromium and WebKit panes.
- Size M. Depends: 020, 021, 022a. Queue: MQ-frameclients.

#### p03-rendering-030 Screen switch springs
- Files: `.../CmuxNextLayout/Views/LayoutRootView+Screens.swift`, `.../CmuxNextLayout/Views/LayoutRootView.swift`.
- Change: screen views frame = rest; RenderSpring position with the screen token; applyScreenFrames loop removed.
- Acceptance: 0 MotionClock frames per switch; landing once.
- Test phase: anim-perf-terminal.py ws-switch.
- Size S. Depends: 019, 020.

#### p03-rendering-031 Canvas camera
- Files: `.../CmuxNextLayout/Canvas/CanvasCameraMotion.swift`, `.../CmuxNextLayout/Views/ScreenContentView+Canvas.swift`.
- Change: stepCanvasCamera replaced by a RenderSpring on the canvas container's sublayerTransform.
- Acceptance: no caller of stepCanvasCamera from advanceFrame; 0 per-frame steps.
- Test phase: canvas e2e if present; motion-main-work.py canvas.
- Size S. Depends: 019, 020.

#### p03-rendering-032 DropHighlightView
- Files: `.../CmuxNextLayout/Views/DropHighlightView.swift`, `.../CmuxNextLayout/Views/LayoutRootView.swift`.
- Change: highlight.step(dt) becomes RenderSpring retargets per drag event (input-driven, O(1)).
- Acceptance: advanceFrame no longer calls highlight.step; 3 zones = 3 retargets, 0 ticks.
- Test phase: drag-lag-live.py.
- Size S. Depends: 020.

#### p03-rendering-033 Sidebar card slot
- Files: `.../CmuxNextSidebar/Views/SidebarCardSlotMotion.swift`, `.../CmuxNextSidebar/Views/SidebarCardTransition.swift`.
- Change: remove MotionAnimating and per-frame `needsLayout = true`; one layout at target height; moved rows get
  RenderSpring position with appear/disappear tokens.
- Acceptance: `rg -n 'MotionAnimating' Packages/macOS/CmuxNext/Sources/CmuxNextSidebar` = 0; 1 layout pass, 0
  MotionClock frames.
- Test phase: sidebar-motion-record.py; sidebar-churn-typing.py not worse.
- Size M. Depends: 020.

#### p03-rendering-034 Window close fade
- Files: `.../CmuxNextApp/Windows/WindowCloseMotion.swift`.
- Change: window non-opaque, shadow off; RenderSpring opacity on the frame-view layer; completion closes; FrameClient
  removed.
- Acceptance: diff deletes `window.alphaValue = max(0, alpha.value)`; offscreen NSWindow test: 0 FrameClient
  activations, close once after completion; gate off closes at once.
- Test phase: RenderStats window_calls during close = 0.
- Size S. Depends: 020. Queue: MQ-window-per-frame.

#### p03-rendering-035 Tab drag ghost
- Files: `.../CmuxNextBridge/TabDrag/TabDragGhostMotion.swift`, `.../CmuxNextApp/Drag/TabDragGhostPanel.swift`.
- Change: inside the source window the ghost is an overlay-plane layer positioned per event; a panel only outside;
  release-to-slot = RenderSpring.
- Acceptance: window_calls during in-window drag = 0; TabDrag.ghost FrameClient removed; drag.tab_to_pane tests pass.
- Test phase: drag-lag-live.py; every-action-sweep drag rows.
- Size M. Depends: 020. Queue: MQ-window-per-frame.

#### p03-rendering-036 Pages resize once in one fence; hosting-off fallback
- Files: `.../CmuxNextBrowser/CEF/CEFHostView.swift`, `CEFHostView+MotionSample.swift`,
  `.../CmuxNextBrowser/WebKit/WebKitPageContainer.swift`, `.../CmuxNextLayout/Views/PaneHostView.swift`,
  `.../CmuxNextBrowser/CEF/ChildWindowPageFallback.swift`.
- Change: pages adopt PaneMotionTargeting (as terminals in 4d). `paneMotionWillRest` sizes the page to the rest
  content size, anchored top-left; hosted pages resize inside one fence for all resized pages (deadline 2 frames,
  task 043); the host fills the uncovered part with the page background (Chrome gutter). Tunable
  `browserResize.springPageResize = once|perFrame` (perFrame = fenced resize per frame, for comparison). Hosting off
  (child windows): at plan apply hide the page window and show its last frame in the host layer (055 path), order it
  in at landing.
- Acceptance: fake engines: one resize per page per Cmd-D at start, none at landing, both engines (F12); hosting off:
  no page window frame differs from its host's presented rect for more than 1 frame; one fence per spring start.
- Test phase: pane-perf-terminal.py --browser (both engines); cef-layer-ab.py light and stress;
  split-new-tab-page-e2e.py.
- Size M. Depends: 022a, 043.

#### p03-rendering-037 GlassBackdropFeed without per-frame JS
- Files: `.../CmuxNextDesign/GlassLens/GlassBackdropFeed.swift`, `.../Tests/CmuxNextDesignTests/GlassBackdropFeedTests.swift`.
- Change: drop the frame/bounds observers; the layout owner calls `layoutWillRest` at plan apply and `landed()`.
- Acceptance: evaluate <= 2 per page per spring, 1 per window resize end; observers removed.
- Test phase: debug.cef evaluate counts in pane-perf-terminal.py --browser, refracting glass on.
- Size S. Depends: 022a. Queue: MQ-frame-observers.

#### p03-rendering-038 Design frame observers
- Files: `.../CmuxNextDesign/ScrollEdgeFade.swift`, `ScrollFitElasticity.swift`, `Overlay/WindowOverlayHost+Present.swift`.
- Change: own NSClipView subclass hooks (scroll(to:), layout) instead of NotificationCenter; overlay host reads size
  in its layout().
- Acceptance: `rg -n 'frameDidChangeNotification|boundsDidChangeNotification' .../CmuxNextDesign` = 0 (except
  GlassBackdropFeed before 037); ScrollEdgeFade tests pass.
- Test phase: swift test --filter 'ScrollEdgeFade|ScrollFit'.
- Size S. Queue: MQ-frame-observers.

#### p03-rendering-039 Sidebar, Terminal, Palette, App observers
- Files: `.../CmuxNextSidebar/Views/SidebarView.swift`, `.../CmuxNextTerminal/TerminalScroller.swift`,
  `.../CmuxNextPalette/PaletteListView.swift`, `.../CmuxNextApp/Control/DebugWebInspector.swift`.
- Change: push from the owning view's layout or scroll hook (P3); drop `postsFrameChangedNotifications` where unused.
- Acceptance: MQ-frame-observers total = 0, or each remaining hit has an AppKit-only reason; sidebar scroll and
  terminal scroller tests pass.
- Test phase: sidebar-perf-validate.py; terminal scroller tests.
- Size S. Queue: MQ-frame-observers.

#### p03-rendering-041 CEF pin API >= 27 without a commit wait
- Files: `scripts/cmux-next/cef-manifest.json`, `.../CmuxNextBrowser/CEF/CEFForkFeatures.swift`,
  `.../CmuxNextBrowser/CEF/CEFSwitches.swift`, `.../Tests/CmuxNextBrowserTests/CEFSwitchesTests.swift`.
- Change: build cmux.33+ (branch cmux/8037-cmux33-layer-host plus API 27 and the skip-`Synchronize()`-for-0-deadline
  patch) with `cmux-ci build cef`, both arches; bump version, sha256, fork_ref, cmux_cef_api_version. If the fork
  lacks the skip patch, keep `enable-features=AsyncLiveResize` for that version (feature flag in CEFForkFeatures).
  R2 upload per the hour-0 decision.
- Acceptance: api version >= 27, both sha256 present; a switches test: for every fork version, either AsyncLiveResize
  is enabled or the fork reports the skip-Synchronize capability; check-first-chromium.py and
  check-cef-objc-contract.py pass; no other code path changes.
- Test phase: cef-resize-sync-bench.py hosting off on the new pin: main wait per commit p99 = 0 (no 50 ms post-commit
  wait); cef-layer-verify.py --checks hosted with the tunable; cef-tab-bench.py not worse.
- Size S. Start hour 0. Owner PL-cef-layer.

#### p03-rendering-042 Fork fence-port resize API
- Files: fork manaflow-ai/cef `libcef/browser/chrome/views/chrome_child_window_mac.mm`; fork
  `components/remote_cocoa/app_shim/native_widget_ns_window_bridge.mm`;
  `Packages/macOS/CmuxNext/CEFShim/src/shim_windows.mm`; `.../CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h`.
- Change: `cmux_browser_set_resize_fence(int browser_id, mach_port_t fence, uint32_t deadline_frames)`: the page's next
  GPU commit at the new size joins the fence; released at the deadline (DeadlinePolicy semantics), on close and on
  crash. Embedded page windows never call `Synchronize()`.
- Acceptance: fork test: an embedded window's geometry change does not enter CATransactionCoordinator's handlers;
  header documents the API version; fence released on every path.
- Test phase: cmux-ci build cef (incremental); cef-resize-sync-bench.py main wait p99 = 0.
- Size L. Depends: 041.
- Landed in the fork at API 32: manaflow-ai/cef `cp/p03-rendering-042` (`741a509a`, on `cp/p01-process-173`,
  the API 31 train line). `cmux_browser_set_resize_fence(id, port, deadline_frames)` replaces API 31's
  `cmux_browser_resize_fence` (a deadline in ms that held the commit): the fork takes its own send right and
  joins the page's context (hosting context, or the page window's own) for the call's turn and for the commit
  that shows the first frame at the new size (`SetCALayerParams` tells the window,
  `-cmuxEmbedderDidReceiveFrame`), then drops it; also at the deadline (display frames, at most 30; 0 after
  the turn's commit), with no resize, and on hide, hosting off and close. An embedded page window never calls
  `Synchronize()` and never waits in pre-commit, so `cmux_browser_set_resize_sync` has no effect from API 32.
  App shim: `cmux_shim_browser_set_resize_fence` (`shim_windows.mm`). From API 32 the shim's
  `cmux_shim_browser_set_resize_sync` makes no call and returns 0, and `CEFLayerHosting` sends the resize deadline
  only to API 27 to 31 (`CEFLayerHosting.hasResizeSync(apiVersion:)`, `resizeFenceForkAPI = 32`). The remote shim
  (host mode) sends no fence op: its `cmux_shim_browser_set_resize_fence` is a local export that returns 0, because a
  Mach port name means nothing in the host; host mode's fence is a port right over XPC (task 052). Task 043's fork
  check is `>= 32` (`resizeFenceForkAPI`; its branch had 31). Embedder case `helper-resize-fence` (not run here: no
  Chromium tree).
- Pin rule: the CEF pin must not move to API 32 until task 043's fence path is the default. At API 32 the resize
  deadline is gone, so with `cefResizeFence` off every page resize shows stale-size frames again (splits, column
  springs, window live resize).

#### p03-rendering-043 App fence transactions
- Files: `.../CmuxNextBrowser/CEF/CEFLayerHosting.swift`, `.../CmuxNextRemoteLayer/include/CmuxNextRemoteLayer.h`,
  `.../CmuxNextBrowser/Core/BrowserResizeTunables.swift`, `.../CmuxNextBrowser/CEF/CEFShimLibrary.swift`.
- Change: one fence port per geometry transaction that resizes hosted pages (divider drag, window live resize,
  spring start from 036); set on the cmux context, passed with deadline_frames=2 to each resized page, released.
  Delete CEFResizeSyncDeadline and the syncDeadline/liveResizeDeadline tunables when the fork API is present.
- Acceptance: Fork-seam tests: one fence per transaction, released on every path (browser closed mid-transaction);
  no main-thread wait API called; older fork keeps API 27 behavior.
- Test phase: cef-resize-sync-bench.py light and STRESS (DC9); column-resize-live.py; devtools-resize-live.py.
- Size M. Depends: 042.

#### p03-rendering-044 Fork: RenderWidgetHostViewCocoa in the embedder view (Track B)
- Files: fork `libcef/browser/chrome/views/chrome_child_window_mac.mm`; fork
  `content/browser/renderer_host/render_widget_host_view_mac.mm` (MigrateNSViewBridge to an in-process parent);
  fork `content/app_shim_remote_cocoa/render_widget_host_ns_view_bridge.mm`; `CEFShim/src/shim_browser.mm`;
  `.../CEF/Shim/cmux_cef_shim.h`.
- Change: `cmux_browser_attach_view(id, NSView* parent)` creates the page's RenderWidgetHostNSViewBridge with its
  RenderWidgetHostViewCocoa as a child of the cmux view. Pixels via its DisplayCALayerTree; input, IME, cursor,
  drag, popups and AX from Chromium's view; visibility follows the parent's window; the page window stays a
  views::Widget and never orders in. Shape kept compatible with the remote_cocoa Application mojom so F2 can reuse it.
- Acceptance: fork test: after attach the Cocoa view's window is the parent's window, the widget window is not
  visible, WasShown fires when the parent window is visible; no NSTextInputClient added in CmuxNext.
- Test phase: cmux-ci build cef; cef-layer-verify.py --checks hosted; check-ime-input.py; AX Inspector dump.
- Size L. Depends: 041, 058. Start hour 0 in parallel with 042.
- Landed in the fork at API 36 (33 is p14-energy-029's, 34 is 058's, 35 is 056's): manaflow-ai/cef
  `cp/p03-rendering-044` (`b5cea1ec`, on `cp/p03-rendering-042`; `a1123260` was the first pass at 33).
  `cmux_browser_attach_view(id, parent_view)` moves the tab's whole WebContentsViewCocoa (not only its
  RenderWidgetHostViewCocoa) into `parent_view`, filling it, as Chrome's NativeViewHostMac adds it to a view of
  the browser window and content_shell shows it: the drag destination (WebDragDest) and Chrome's own visibility
  path (`-[WebContentsViewCocoa updateWebContentsVisibility]`, the occlusion checker) are on that view, so
  WasShown/WasHidden follow the parent view and its window with no embedder visibility call (task 058's override
  is for hosted page windows; attached pages do not need it). Each RenderWidgetHostViewMac leaves the Views parent
  `ui::Layer` (own `ui::Compositor`) and its bridge's DisplayCALayerTree comes back
  (`RenderWidgetHostNSViewBridge::EnableDisplay`, patch `cmux_embedder_attach_view`; the WebContentsViewMac part is
  in `cmux_remote_popup_menu.patch`, one patch per Chromium file). Views still attaches and detaches the tab
  (Chromium's active tab decides visibility); its bounds are ignored while attached. The page window stays the
  tab's views::Widget, headless as a detached page's while any of its tabs is attached; layer hosting, detached
  hosting and the resize fence refuse it then. Its frame, visibility and active state follow the view that shows
  its attached tabs (the active tab's when attached), which may be in another window than the view it was created
  over. A TabStripModelObserver keeps that state equal to what the tabs give: a page window turns headless when an
  attached tab moves in, and shows again when its last attached tab closes, moves out or is given back (NULL).
  App shim: `cmux_shim_browser_attach_view` (`shim_browser.mm`); the remote shim's is a local stub that returns 0
  (an NSView* means nothing in the host; F2's form is remote_cocoa's Application mojom). Embedder case
  `helper-attach-view` (not run here: no Chromium tree). Pin rule: as for 042, the pin moves only with a CEF build of
  this ref. Task 045 binds the export with `r.optional` and gates on `forkAPIVersion >= 36`
  (`CEFLayerHosting.attachViewForkAPI`): the app shim exports the call in every build, and a fork without
  `cmux_browser_attach_view` (another line, at any number) makes it answer 0, a refusal the app already handles.
- Open for 046: Views bubbles anchored in the page window (autofill, extension popups, the side panel) belong to
  the headless page window, so they need the hosted-widget path (API 31) or a per-widget fallback.

#### p03-rendering-045 App adopts the attached Chromium view
- Files: `.../CmuxNextBrowser/CEF/CEFHostView.swift`, `CEFLayerHosting.swift`, `CEFHostedPageView.swift`.
- Change: with the attach API, CEFHostView attaches once per browser, sizes the view in layout(), keeps the KeyRouter
  before Chromium's view (performKeyEquivalent order unchanged). CEFHostedPageView and the context-id path become
  the fallback.
- Acceptance: Fork-seam test: one attach per browser, 0 page windows ordered in, first responder after a page click
  is Chromium's view; fallback tests unchanged.
- Test phase: cef-layer-ab.py switch/tabs STRESS; browser-use e2e clicks, typing, drag; check-ime-input.py.
- Size M. Depends: 044.

#### p03-rendering-046 Chromium native UI on the attached view
- Files: `.../CmuxNextBrowser/CEF/CEFHostView.swift`, `.../CmuxNextBrowser/CEF/CEFRuntime+Events.swift`, fork patches as
  found.
- Change: verify and fix on the attached view: `<select>` popups, context menus, autofill/password dropdowns, color
  and date pickers, print preview, IME (Japanese, Korean, dead keys, emoji picker), file drop in and link drag out
  (CEFFileDragRelay scope rules kept), VoiceOver, tooltips, cursor.
- Acceptance: each item has a fleet e2e or a recorded manual check with capture; failures are fixed or listed as
  per-widget fallback to the page window.
- Test phase: check-ime-input.py; drag e2e; AX dump; capture tour.
- Size M. Depends: 045.

#### p03-rendering-050 Layer hosting on by default (Track A)
- Files: `.../CmuxNextBrowser/Core/BrowserResizeTunables.swift`, `plans/cmux-next/cef-layer-hosting-DESIGN.md`,
  `plans/cmux-next/rendering-DESIGN.md`.
- Change: `browserResize.layerHosting` default true when the fork is >= 27 with fence and embedder visibility (API 26/27
  transparent input window). Per-widget fallback to the page window where hosting is refused (DevTools, popups until
  056). Update the section 3 feature table.
- Acceptance: one default change plus the doc table; cef-layer-verify.py all checks pass with no tunable; drag and
  drop, AX and docked DevTools work through the input window or the per-widget fallback (e2e list in the PR).
  Before the default flips, rendering-DESIGN.md difference 2 records the measured IOSurface and GPU bytes for each
  hosted page (bench_memory.py) and the wakeups for each visible page (bench_idle.py).
- Test phase: cef-layer-ab.py full run on 26 and 27; DC8a, DC9, DC10; bench_memory.py (IOSurface and GPU bytes for
  each hosted page); bench_idle.py (wakeups for each visible page).
- Size S. Depends: 041, 043, 058.

#### p03-rendering-051 Delete divider catcher panels
- Files: `.../CmuxNextLayout/Views/DividerMouseCatchers.swift`, `.../CmuxNextApp/Windows/WindowOverlayLayer.swift`,
  `.../CmuxNextLayout/Views/LayoutRootView.swift`.
- Change: catchers only while a page child window or input window is visible (fallback); with attached views the
  divider views take the mouse in-window.
- Acceptance: with attached views, panelUpdates = 0 and no panel created; fallback tests pass.
- Test phase: pane-perf-terminal.py --browser; divider drag over a page e2e.
- Size M. Depends: 045. Owner PL-motion-cef.

#### p03-rendering-052 Overlays in an in-window top layer
- Files: `.../CmuxNextDesign/Overlay/WindowOverlayHost.swift`, `WindowOverlayHost+Present.swift`,
  `.../CmuxNextApp/Windows/WindowOverlayLayer.swift`, `.../CmuxNextApp/Windows/WindowController.swift`.
- Change: tooltips, toasts, dialogs and ghosts present in a top overlay view above the layout root; the child panel
  and per-event re-ordering exist only for the fallback or out-of-window content.
- Acceptance: with attached views no panel is created and childWindowsDidChange re-ordering does not run; every
  overlay kind above a page (layer order test); dialog key handling unchanged.
- Test phase: cmux-ci capture of dialogs and toasts over a Chromium pane; every-action sweep overlay rows.
- Size L. Depends: 045.

#### p03-rendering-053 Child-window path into one fallback file
- Files: `.../CmuxNextBrowser/CEF/CEFHostView.swift`, `CEFClipShape.swift`,
  `.../CmuxNextBrowserCore/Engine/BrowserWindowOcclusion.swift`, `.../CmuxNextBrowser/UI/PageFloatingOverlays.swift`,
  `.../CmuxNextApp/WindowRootView+MainPane.swift`, `.../CmuxNextLayout/Views/ScreenContentView+Dock.swift`,
  `.../CmuxNextBrowser/CEF/ChildWindowPageFallback.swift`.
- Change: move cmuxClipPath, cmuxOcclusionRects, the browserChildWindowPagesNeedUpdate notification and cutouts into
  the fallback file behind the hosting-refused state; geometry messages only on rect change.
- Acceptance: DC8b rg = 0 outside the fallback file; notification name not referenced elsewhere; tests pass.
- Test phase: cef-layer-ab.py; pane-perf-terminal.py --browser STRESS.
- Size M. Depends: 045.

#### p03-rendering-054 Show/hide in the switch's transaction
- Files: `.../CmuxNextBrowser/CEF/CEFPaneHost+Show.swift`, `CEFLayerHosting.swift`, fork keep-frame-while-hidden.
- Change: show unhides the CALayerHost (or attached view) in the switch's transaction; WasShown/WasHidden after
  the commit; frames kept per HiddenFrameLRU (099), not per pane.
- Acceptance: Fork seam: 0 fork calls in the switch's turn, 1 after commit; show.again passes.
- Test phase: cef-layer-ab.py switch/tabs STRESS (DC10).
- Size M. Depends: 050, 099.

#### p03-rendering-055 Hidden page volatile snapshot
- Files: `.../CmuxNextBrowser/CEF/CEFHostedPageView.swift`, `CEFLayerHosting.swift`,
  `.../CmuxNextHibernation/BrowserHibernation.swift`.
- Change: after the grace, capture off main into a volatile IOSurface, drop the CALayerHost, let the renderer evict;
  show draws the snapshot in the first commit, live on the first renderer frame; a purged snapshot shows the
  background.
- Acceptance: hidden-past-grace state: no layer host, one volatile snapshot; show presents it in the same turn.
- Test phase: bench_memory.py hidden tab memory lower; show.again.
- Size M. Depends: 054.

#### p03-rendering-056 DevTools and popups hosted
- Files: `.../CmuxNextBrowser/CEF/CEFDevToolsController.swift`, `CEFPaneHost+PopupWindows.swift`, fork per-widget hosting.
- Change: DevTools (docked and own window), popup windows and extension popups get hosting (and attach in Track B).
- Acceptance: Fork-seam tests per kind; tracker.hosted_pages counts them.
- Test phase: devtools-resize-live.py; extension popup e2e.
- Size L. Depends: 050. Queue: MQ-child-window-pages.

#### p03-rendering-058 Fork: visibility from the embedder
- Files: fork `chrome_child_window_mac.mm`; fork `content/browser/web_contents/web_contents_occlusion_checker_mac.mm`;
  `CEFShim/src/shim_browser.mm`; `.../CEF/Shim/cmux_cef_shim.h`.
- Change: `cmux_browser_set_embedder_visibility(id, visible|hidden|occluded)`; for hosted embedded windows, NSWindow
  occlusion and order state do not change WebContents visibility.
- Acceptance: fork test: a never-ordered-in page marked visible keeps producing frames (rAF count rises); hidden
  stops them.
- Test phase: cmux-ci build cef; cef-layer-verify.py hosted with the input window off screen.
- Size M. Depends: 041.
- Landed in the fork at API 34 (33 is p14-energy-029's): manaflow-ai/cef `cp/p03-rendering-058` (`e9d12702`, on
  `cp/p03-rendering-042`). `cmux_browser_set_embedder_visibility(id, window|visible|occluded|hidden)` applies while
  the page is layer hosted: the tracker stores it on the `CefNSWindow` and the Views bridge's `OnVisibilityChanged`
  reads it instead of the window's order (visible and occluded keep the compositor running, hidden suspends it);
  occluded sets content's `-setOccluded:` (Chrome's one second of coalescing), and `WebContentsOcclusionCheckerMac`
  leaves the window alone (`cmux_embedder_visibility.patch`). The page window is then the input target only and its
  order changes nothing for the page; `window` (0, the default) gives the decision back to the order. App shim:
  `cmux_shim_browser_set_embedder_visibility` (`shim_browser.mm`, `cmux_shim_embedder_visibility_t`), a `post` op in
  host mode. Only the fork call and this shim export landed: no app code calls
  `cmux_shim_browser_set_embedder_visibility` yet, and the `.embedderVisibility` bit in `CEFLayerHosting.TrackA` is
  older base code that nothing sets. p03-rendering-050 owns the app side: the Swift binding, an
  `embedderVisibilityForkAPI = 34` constant, and inserting `.embedderVisibility` into TrackA only when
  `forkAPIVersion >= 34`, with a CEFLayerHostingDefaultTests case. 050 must not turn layer hosting on before that
  caller sends visibility, or a never-ordered-in page window reads as occluded and stops drawing. p03-rendering-097
  then sends `occluded` from WindowOcclusionFamily. Embedder case `helper-embedder-visibility` (not run here: no
  Chromium tree).

#### p03-rendering-060 / 061 Redraw policy (Sidebar 28 files; the rest 31 files)
- Files: the MQ-redraw-policy files (060: CmuxNextSidebar; 061: all others).
- Change: `layerContentsRedrawPolicy = .onSetNeedsDisplay` for updateLayer views, `.never` for containers.
- Acceptance: comm list empty for the scope; each converted view draws with layer properties only, or sets
  contentsCenter with matching gravity, or `.topLeft` gravity with needsDisplay behind a size-changed check; a capture
  at 50 % of a Cmd-D spring shows no stretched chrome.
- Test phase: sidebar-perf-validate.py (060), anim-perf-terminal.py (061); RenderStats damage during resize lower;
  capture stills light and dark.
- Size S each. Depends: 001. Queue: MQ-redraw-policy.

#### p03-rendering-062 / 063 / 064 / 065 Invalidation by measured owner
- Files: owners listed by task 003 in CmuxNextSidebar (062), CmuxNextHome and CmuxNextHomeEngine (063), CmuxNextDesign
  and CmuxNextApp (064), all other packages (065).
- Change: for each owner with damage > 0 at idle or frame sets/layouts in motion frames 2..n: guard each invalidation
  with a value change or `// invalidate: <why>`; remove ancestor invalidation from child setters.
- Acceptance: per owner, a red RenderStats count at base and green at head in the commit; `render-done-checks.py
  --invalidate` reports 0 unguarded hits in the edited files; capture stills of the package's chrome.
- Test phase: render-idle-damage.py owner = 0; sidebar-churn-typing.py (062); home-perf.py and typing-frame-bench.py
  Home composer (063); anim-perf-terminal.py (064); bench-typing.py omnibar and palette (065).
- Size M/S/M/M. Depends: 003. Queue: MQ-damage-owners.

#### p03-rendering-066 Guardrail sync-layout
- Files: `scripts/cmux-next/guardrails.py`, `tests/test_cmux_next_guardrails.py`.
- Change: rule `sync-layout`: added lines with layoutSubtreeIfNeeded, displayIfNeeded, `.display()` or
  CATransaction.flush need `// sync-layout: <why>` on the line or above; added lines only; fails open.
- Acceptance: red on an unannotated added call, green annotated; `--list` names it; no `.github` change.
- Test phase: `python3 tests/test_cmux_next_guardrails.py` (portable).
- Size S. Owner PL-guardrails.

#### p03-rendering-067 / 068 / 069 Forced sync layouts (App 22; Design 13 + popup flush; the rest)
- Files: MQ-sync-layout hits per scope; 068 adds `.../CmuxNextDesign/Motion/Motion+Popup.swift`.
- Change: remove each call whose result is not read in the same turn; keep with a reason naming the read otherwise.
  068: popup flush becomes ordering the window in from the commit's completion block.
- Acceptance: 067/069 every hit removed or annotated; 068 `rg -n 'CATransaction\.flush' Packages/macOS/CmuxNext/Sources`
  = 0 outside comments and the popup shows in the key's frame (MotionCommitProbe test); 069 DC11 tree-wide.
- Test phase: every-action-sweep windows/workspaces shard (067); anim-perf-terminal.py palette-open (068);
  bench-typing.py (069).
- Size M/S/M. Depends: 066.

#### p03-rendering-070 Loops stop when hidden or occluded
- Files: `.../CmuxNextDesign/Motion/Motion+AppKit.swift`, `.../CmuxNextDesign/Motion/LoopVisibility.swift` (new),
  `.../CmuxNextDesign/NightSky/NightSkyView.swift`, `.../CmuxNextDesign/Motion/Motion+Wiggle.swift`,
  `.../CmuxNextSidebar/Views/SidebarNowPlayingControls.swift`.
- Change: every infinite loop goes through `LoopVisibility.attach(layer, key, make:)`, which removes it when the view
  leaves the window, is hidden, or the window is occluded (WindowOcclusionFamily), and re-adds it with phase from
  media time (P10).
- Acceptance: every MQ-loops hit goes through LoopVisibility; hidden spinner 0 animations, shown 1.
- Test phase: render-idle-damage.py loop owners in hidden/occluded windows = 0; bench_power.py.
- Size M. Depends: 001, 097.

#### p03-rendering-071 / 072 / 073 Pane chrome without Auto Layout
- Files: 071 `.../CmuxNextBrowser/UI/AddressBarView.swift`, `OmnibarToolbarView.swift`, `OmnibarViews.swift`,
  `BrowserChromeView.swift`, `BrowserChromeView+AccessoryBar.swift`, `BrowserToolbarButtonsView.swift`,
  `ChromeButtons.swift`. 072 `PageStatusViews.swift`, `PageGoneView.swift`, `PageUnresponsiveView.swift`,
  `LoadErrorView.swift`, `BrowserNoticeView.swift`, `PromptBarView.swift`, `FindBarView.swift`,
  `PageFloatingOverlays.swift`. 073 `.../CmuxNextTerminal/TerminalStatusBanner.swift`, `TerminalSizedForChip.swift`,
  `TerminalFindBarView.swift`, `TerminalCopyModeBadge.swift`, `.../CmuxNextTabs/TabHoverCardView.swift`,
  `.../CmuxNextBrowser/UI/ProfileBadgeView.swift`, `MachineBadgeView.swift`, `FocusModeBadgeView.swift`.
- Change: frame layout in layout() from a pure, unit-tested function of bounds and content.
- Acceptance: the files have no `translatesAutoresizingMaskIntoConstraints = false`; layout tests for narrow, normal,
  wide, RTL and accessory states; capture stills match. 073: the queue lists only TabGroupEditor*, DemoContentView,
  side-panel and cookie cards, each with a reason.
- Test phase: cmux-ci capture light and dark; omnibar-click-bench.py (071); bench-terminal-resize.py (073).
- Size L/L/M.

#### p03-rendering-074 Home composer chrome as layers
- Files: `.../CmuxNextHomeEngine/HomeComposer.swift`, composer chrome views under `.../CmuxNextHome/NativeTranscript/`.
- Change: static chrome (border, placeholder, buttons, hint row) becomes CALayers under one NSView; a key invalidates
  only the text view's line. Coordinate with PL-typing.
- Acceptance: one key causes 0 layout() outside the text view and 1 damage rect; composer NSView count drops.
- Test phase: typing-frame-bench.py Home composer light and loaded: p95 <= 8.3 ms at 120 Hz.
- Size L. Depends: 001.

#### p03-rendering-075 Shared GlyphMask cache
- Files: `.../CmuxNextDesign/Text/GlyphMask.swift`, `GlyphMaskCache.swift` (new), `ChromeLabel.swift`.
- Change: masks keyed by (string, font, size, scale, line settings, weight) in a bounded byte-limited LRU built in
  AppServices (P1).
- Acceptance: two equal labels rasterize once; byte limit honored; LabelParityProbe passes.
- Test phase: sidebar-mirror-rebuild-perf.py main ms lower.
- Size S. Queue: MQ-labels.

#### p03-rendering-079 Ghostty integrator lane
- Files: `ghostty-next` (gitlink), `docs/ghostty-fork.md`, `plans/cmux-next/rendering-DESIGN.md`.
- Change: PL-ghostty lands ghostty-next PRs in order 088, 089, 082, 017-spike result then 080, 084, 090, 086, 087,
  092; at most 3 GhosttyNextKit builds and pin bumps in 72 h; app tasks rebase onto each pin.
- Acceptance: each pin commit names its PRs; the gitlink equals the GhosttyNextKit source sha; render-done-checks.py
  verifies submodule init at that sha.
- Test phase: zig build test per PR on the fleet; GhosttyNextKit build per pin.
- Size S. Start hour 0.

#### p03-rendering-080 ghostty-next: present off main (form from 017)
- Files: `ghostty-next/src/renderer/metal/IOSurfaceLayer.zig`, `src/renderer/Metal.zig`, `src/apprt/embedded.zig`,
  `include/ghostty.h`.
- Change: implement the 017 form. The renderer is the only writer of presented contents; the size check reads an
  atomic host size written by set_size; the main dispatch_async is removed; add
  `ghostty_surface_presented_frame(surface) -> IOSurfaceRef (+1)` and a presented callback (surface, frame id, mach
  time; presentedTime where CAMetalLayer gives it); add `ghostty_surface_set_presentation(hidden|shown|purge)`.
  The leaf layer is retained until the renderer stops.
- Acceptance: (initialized) `rg -n 'dispatch_async|queue.getMain' src/renderer/metal/IOSurfaceLayer.zig` = 0; wrong-size
  frame dropped by the atomic check (test); no non-main CATransaction touches a layer whose superlayer belongs to an
  NSView (rule 5); detach main-safe; teardown test.
- Test phase: `git submodule update --init ghostty-next`; zig build test on the fleet; GhosttyNextKit build.
- Size M. Depends: 017.
- Fork state (2026-10-26): ghostty-next branch `cp/p03-rendering-080`, commit f60815cf5, on the 017 spike
  (6fb98534e). Form (a) only; the spike's `macos-present-form` key is gone. The renderer copies each frame into a
  drawable of an overlay `CAMetalLayer` (`presentsWithTransaction = false`, `DrawablePresenter.zig`), taken before
  the draw lock. Main writes only the view's layers; a main present (first frame, sync draw, resize pre-commit) hides
  the overlay, and the first frame encoded after it asks main once through the app mailbox (`present_reveal`, run in
  `ghostty_app_tick`, not a Ghostty `dispatch_async`) to show it again (`PresentState.zig` hide generations).
  Frames of a size other than the drawable size are dropped; `setHostDrawableSize` sets the drawables before the
  atomic host size. New C API: `ghostty_surface_config_s.presented_cb`/`presented_userdata` (frame id, host time,
  `presentedTime`; delivery stops before `ghostty_surface_free` returns, `PresentedSink.zig`),
  `ghostty_surface_presented_frame` (+1), `ghostty_surface_set_presentation` (HIDDEN, SHOWN, PURGE). The config
  struct grows to 128 bytes; Swift must zero-init it (`ghostty_surface_config_new`). The gitlink is not moved: it must
  match the pinned GhosttyNextKit, and 081 adopts this at the pin bump (the cmux leaf reads `layer.contents`
  today, which now holds a frame only until the renderer's next one). Costs to measure on the fleet: one GPU blit and
  three drawables per surface next to the swap chain (`bench_memory.py`), the `nextDrawable` wait histogram
  (`present_form` log line, `ghostty-present-form-bench.py`).
- Fork fixes (2026-10-27): commit 612a8ff99 on the same branch, after review. `nextDrawable` never runs under the
  draw lock: a frame whose drawable has the size from before a resize is dropped and drawn again at once with a
  drawable taken outside the lock (`stale_drawables` in the `present_form` line). The reveal request comes from the
  drawable's presented handler, not the command buffer's completion, so no older drawable can show after it. Every
  `set_size` and `set_content_scale` syncs the overlay's geometry and scale and the drawable size (a display scale
  change keeps the bounds); 081 must set the root layer's `contentsScale` before those calls, as upstream Ghostty's
  `viewDidChangeBackingProperties` does (the cmux leaf does not today). The overlay is `opaque` only for
  `background-opacity` >= 1 without glass, also on a config reload. A hidden or purged presentation draws nothing in
  the display pass; a purge clears the overlay's drawable, and a frame encoded before a hide, purge or main present
  never becomes `ghostty_surface_presented_frame`.

#### p03-rendering-081 cmux adopts renderer-owned frames
- Files: `.../CmuxNextTerminal/TerminalSurfaceView.swift`, `TerminalFrameHold.swift`, `TerminalFramePurgeability.swift`,
  `TerminalLastFrame.swift`, `TypingFrameProbe.swift`, GhosttyNextKit pin.
- Change: pin bump; presentedFrame, frame hold, last frame, purgeability and typing probe read the Ghostty API; the
  view's layer is a container; the hold view stays above the leaf.
- Acceptance: no per-frame `layer?.contents` read in CmuxNextTerminal; TerminalFrameHold, TerminalLastFrame,
  TerminalResizeFrameTests pass.
- Test phase: DC6; bench-typing.py terminal light and STRESS; evicted-terminal-frame-live.py.
- Size M. Depends: 080.

#### p03-rendering-082 ghostty-next: external vsync
- Files: `ghostty-next/src/renderer/generic.zig`, `src/renderer/Thread.zig`, `src/apprt/embedded.zig`, `include/ghostty.h`.
- Change: surface config `vsync_external`; `ghostty_surface_vsync(surface, target_ns)` and a wants-vsync change
  callback; with external vsync no DisplayLink is created and the loop draws on the vsync message.
- Acceptance: counter test: `createWithActiveCGDisplays` not called with the flag; standalone behavior unchanged.
- Test phase: zig build test (initialized submodule).
- Size M. Queue: MQ-displaylinks.
- As built (ghostty-next branch cp/p03-rendering-082, 7436f3b9a, draft PR manaflow-ai/ghostty-next#59; 083 writes
  against this):
  - `ghostty_surface_config_s` gets `bool vsync_external`, `ghostty_surface_vsync_wanted_cb vsync_wanted_cb`,
    `void* vsync_userdata`, after `io_write_userdata` (64-bit offsets 112, 120, 128; size 136).
    `ghostty_surface_new` fails when `vsync_external` is set without the callback. Split surfaces Ghostty asks
    for do not inherit the fields.
  - `void (*ghostty_surface_vsync_wanted_cb)(void* userdata, bool wanted)` runs on the renderer thread, on each
    edge only (calls alternate, starting with true): true when the surface is visible and has a new frame or an
    animation (the same condition that started the CVDisplayLink), false when idle or hidden, and false once more
    when the renderer thread exits. It may call `ghostty_surface_vsync` and nothing else in Ghostty.
  - `void ghostty_surface_vsync(ghostty_surface_t)`: one refresh; any thread, from `ghostty_surface_new` until
    `ghostty_surface_free` is called; no effect without `vsync_external`. It notifies the renderer thread's
    `draw_now`, the async a display link of its own notifies, so frames, coalescing and the early first frame
    after idle (`drawsNow`) are the same as standalone.
  - Differences from the spec: no `target_ns` argument. The tick draws at once and the renderer has no use for a
    deadline (a stale tick still draws the newest cells); a deadline goes with the BeginFrame-args work, not here.
    The tick is the `draw_now` async, not a mailbox message, so a burst of ticks coalesces as link ticks do.
    `ghostty_surface_set_display_id` does not change pacing under external vsync: the embedder moves the surface to
    its display's clock (083).
  - Pacing lives in `ghostty-next/src/renderer/vsync.zig` (`Pacer`). Standalone, the link is made, run and stopped
    as before; the "vsync external" tests count the link factory (0 calls of `createWithActiveCGDisplays` with the
    flag). The flag reaches the renderer as `renderer.Options.vsync_external`, which `Surface.zig` sets from the
    embedded surface only (`apprt.runtime == apprt.embedded`, so a renamed field fails the lib build). The test
    "renderer external vsync: ..." runs `renderer.Renderer`'s own sync with its real link factory and counts 0
    link creates. The gitlink and the GhosttyNextKit pin do not move here: 082 rides pin 1 (task 079).

#### p03-rendering-083 cmux drives surfaces from VSyncHub
- Files: `.../CmuxNextTerminal/TerminalVSync.swift` (new), `TerminalSurfaceView.swift`, `GhosttyRuntimeCallbacks.swift`.
- Change: visible surfaces subscribe to their display's hub while they want vsync, move on display id change; hidden
  and occluded surfaces never subscribe.
- Acceptance: fake hub: hidden 0 subscriptions, idle visible disarms after one empty tick; DC1 holds.
- Test phase: DC1, DC6, DC7r; bench-typing.py not worse.
- Size M. Depends: 014, 082.

#### p03-rendering-084 Pre-commit present never waits; frame sequence
- Files: `ghostty-next/src/renderer/Metal.zig` (presentHostSized), `.../CmuxNextTerminal/TerminalHostFramePresenter.swift`.
- Change: at the pre-commit observer, present the new-size frame only if ready, else keep the last frame; remove the
  futex wait. Both paths carry a monotonic frame sequence in shared atomic state and commit only if newer
  (compare-and-swap). Start from branches plghx-fg-green and plghx-next2.
- Acceptance: no futex/wait in presentHostSized; a ghostty-next test interleaves the two writers and never shows an
  older frame after a newer one; TerminalResizeFrameTests: no stale text at a new size.
- Test phase: bench-terminal-resize.py light drag: main p95 per drag frame <= base 12.2 ms, drops <= base;
  fresh_presents and late_presents reported.
- Size M. Depends: 080.

#### p03-rendering-085 Grid, snapshot and status off the main actor (G4 rest)
- Files: `.../CmuxNextTerminal/TerminalSession.swift`, `TerminalSession+Output.swift`, `TerminalGridLock.swift`,
  `TerminalOutputLane.swift`.
- Change: grid locks and READY restores queued on the lane (lane-side generation); status and sizedFor coalesced to
  one main turn per frame through FrameBatchQueue; the events loop never waits for main.
- Acceptance: TerminalOutputOffMainTests extended: with main held, output and grid steps reach the lane in order; main
  turns per second from a busy terminal <= frame rate.
- Test phase: bench-typing.py with 10 printing terminals STRESS: key to frame p99 <= 16.7 ms.
- Size L (split lane-side grid lock and status coalescing into two PRs).

#### p03-rendering-086 Manual-IO surfaces: no IO thread
- Files: `ghostty-next/src/Surface.zig`, `src/termio/Manual.zig`, `src/renderer/Thread.zig`.
- Change: no termio thread in manual IO mode; its timers move to the renderer loop.
- Acceptance: thread count per manual surface = 1 (test).
- Test phase: zig build test; thread count with 20 terminals about 20 lower.
- Size M.

#### p03-rendering-087 Shared atlas and command queue
- Files: `ghostty-next/src/renderer/generic.zig`, `src/renderer/Metal.zig`, `src/font/SharedGrid.zig`.
- Change: atlas textures per SharedGrid (refcounted), uploaded once; one MTLCommandQueue per device.
- Acceptance: two surfaces with one font share the texture; atlas growth reaches every user (generation number).
- Test phase: bench_memory.py per-terminal memory lower; instant-new-surfaces-bench.py not worse.
- Size L.
- Fork state (2026-10-27): ghostty-next branch `cp/p03-rendering-087`, commit ee4a66a43, on 080's 612a8ff99.
  `src/renderer/AtlasTexture.zig` (new) is a refcounted texture per atlas with a generation (Skia's
  `GrDrawOpAtlas` atlas generation): growth makes a new texture and every frame of every surface moves to it on
  its next sync; the old texture goes with its last reference. `font.SharedGrid.textures` holds them, synced
  under the grid lock held exclusively, so a changed atlas uploads once for all surfaces (before: once into each
  of the 3 frames of each surface). Metal shares them (`atlas_textures_per_device`); OpenGL contexts share no
  objects, so each OpenGL renderer keeps its own. `metal/Device.zig` owns the one MTLCommandQueue (max 1024
  command buffers), as ANGLE's `DisplayMtl` does. No C API change; the gitlink is not moved (task 079 lands it
  after 080). Linux: `zig build test -Dapp-runtime=none` passes with the OpenGL renderer compiled; Metal code is
  compiled and the "one command queue per device" test runs only on the fleet.
- Fork state, review fixes (2026-10-27): ghostty-next commit 338323476 on ee4a66a43. (1) The Metal upload is no
  longer a CPU `replaceRegion` into a texture that frames in flight sample: `Metal.uploadAtlasTexture` blits
  from a staging buffer in a command buffer committed on the device's one queue, so it runs after every frame
  committed before it and before every frame committed after it (commit order plus Metal hazard tracking), as
  Skia defers atlas uploads into the flush (`GrOpFlushState::doUpload`). Atlas textures are `private` storage.
  `uploaded` is published only after the upload is submitted. (2) The sync takes the grid lock shared, as glyph
  lookups do; each `AtlasTexture` has its own `std.Io.Mutex` for `current`/`generation`/`uploaded`, so one
  surface's upload no longer stops text work on other surfaces.

#### p03-rendering-088 Renderer QoS by visibility
- Files: `ghostty-next/src/renderer/Thread.zig`, `src/termio/Termio.zig`, `plans/cmux-next/threading-model.md`.
- Change: userInteractive focused+visible, userInitiated visible, utility hidden; wakeup counter; process_output on a
  hidden surface sets dirty without waking.
- Acceptance: red commit (counter, test fails at 723c4ab) before the fix; threading-model.md row.
- Test phase: zig build test; bench_idle.py 10 hidden printing terminals: CPU lower.
- Size S.

#### p03-rendering-089 No frame when nothing changed (G7 rest)
- Files: `ghostty-next/src/renderer/generic.zig`, `src/renderer/Thread.zig`.
- Change: skip rebuild and draw with no dirty row, no cursor change, no size change; remove the 600 ms focused rebuild.
- Acceptance: TerminalIdleCursorFrameTests: steady focused cursor draws 0 frames in 10 s (red at base).
- Test phase: render-idle-damage.py Ghostty frames at idle = 0 (with 091).
- Size S.

#### p03-rendering-090 ghostty-next: external cursor with cell image
- Files: `ghostty-next/src/renderer/generic.zig`, `src/renderer/cursor.zig`, `src/apprt/embedded.zig`, `include/ghostty.h`.
- Change: with `cursor_external`, the renderer does not draw or blink the cursor. On a cursor move or a cell change
  it renders the cursor cell (block with the glyph in cursor-text color, or bar/underline/hollow) into a small
  IOSurface and publishes rect, style, visibility and that surface through a callback. Disabled when a custom shader
  is set.
- Acceptance: no renderer wake for 2 s of blink; one callback per move; block-cell pixels equal Ghostty's own draw.
- Test phase: zig build test.
- Size M.

#### p03-rendering-091 TerminalCursorLayer
- Files: `.../CmuxNextTerminal/TerminalCursorLayer.swift` (new), `TerminalSurfaceView.swift`, `GhosttyRuntimeCallbacks.swift`.
- Change: a sublayer above the content shows the cursor-cell surface; blink is a discrete keyframe on opacity through
  LoopVisibility with the config interval; Reduce Motion or blink off = steady; copy mode and IME marked text keep
  their drawing.
- Acceptance: blink adds 0 Ghostty frames over 3 s; cursor rect = cell rect after a move; motion gate respected
  (`// motion: allow` only with the config reason); block cursor over a character pixel-compare passes.
- Test phase: DC7r; capture stills per cursor style light and dark; check-ime-input.py.
- Size M. Depends: 090, 070.

#### p03-rendering-092 Buffer-age partial redraw (purge-aware)
- Files: `ghostty-next/src/renderer/generic.zig`, `src/renderer/Metal.zig`, `src/renderer/metal/Target.zig`.
- Change: each swap-chain frame keeps damage since last drawn; loadAction .load with a scissor to the dirty-row union;
  full redraw on resize, scroll, theme, new target, and after any makeVolatile, failed reclaim, or a hold/last-frame
  reader keeping the buffer.
- Acceptance: one typed character redraws one row band with output equal to a full redraw; a purged buffer forces a
  full redraw (test).
- Test phase: bench_power.py typing; typing-frame-bench.py not worse.
- Size L. Depends: 089.

#### p03-rendering-093 Terminal frame ownership: probes, counters, hide/show
- Files: `.../CmuxNextTerminal/TypingFrameProbe.swift`, `TerminalSurfaceView.swift`,
  `.../CmuxNextDesign/Diagnostics/RenderStats.swift`, `ghostty-next/include/ghostty.h`.
- Change: TypingFrameProbe uses the Ghostty presented callback, not the setContents swizzle; TerminalSurfaceView stops
  writing the leaf contents (today lines 473 and 484) and calls `ghostty_surface_set_presentation`.
- Acceptance: `rg -n 'layer\?\.contents = ' Packages/macOS/CmuxNext/Sources/CmuxNextTerminal` has no hit on the leaf;
  TSan run of TerminalOutputOffMainTests and the typing probe test is clean; DC5 at base equals the old probe within
  0.5 ms.
- Test phase: swift test -sanitize=thread on the fleet; bench-typing.py light and STRESS.
- Size M. Depends: 080.

#### p03-rendering-096 Hidden workspace: hide plus evict, detach by measurement
- Files: `.../CmuxNextLayout/Views/LayoutRootView+Screens.swift`, `.../CmuxNextApp/WindowRootView+MainPane.swift`.
- Change: in the switch's turn set the previous root `isHidden = true`; evict content as its own step (terminal
  purge, page eviction via HiddenFrameLRU); measure detach-after-grace (budgeted idle) against hide-only in
  activation-perf.py STRESS and keep detach only if it saves memory with switch-in p95 < 8.3 ms. Tell PL-switch.
- Acceptance: switch-in to a recently hidden workspace makes 0 viewDidMoveToWindow calls (test); the PR states both
  measurements; DC12 bytes.
- Test phase: activation-perf.py workspace_switch light and STRESS; bench_memory.py.
- Size M. Depends: 109, 099.

#### p03-rendering-097 WindowOcclusionFamily with the same-size check
- Files: `.../CmuxNextWakeups/WindowOcclusionFamily.swift` (new), `.../CmuxNextWakeups/FrameScheduler.swift`,
  `.../CmuxNextTerminal/TerminalSurfaceView.swift`, `.../CmuxNextBrowser/CEF/CEFLayerHosting.swift`.
- Change: occluded = system occlusionState not visible, or the window is fully covered by an opaque cmux window above
  it (recomputed on order, move, resize, close, miniaturize; crbug.com/883031). Ordered subscribers: content
  producers before diagnostics. Non-essential frame clients pause, Ghostty surfaces marked occluded, pages get
  embedder visibility occluded (058), loops come off.
- Acceptance: fake signal: 0 ticks and 0 vsync subscriptions in an occluded window, one restore on visible; two
  same-size cmux windows: the back one is occluded while the fake system state says visible.
- Test phase: bench_idle.py --scenarios app-hidden, covered-window (two same-size windows): main wakes <= 0.5/s.
- Size M. Depends: 010.

#### p03-rendering-098 Hit testing through the presentation tree
- Files: `.../CmuxNextLayout/Views/LayoutRootView.swift`, `PaneHostView.swift`, `ScreenContentView+Dock.swift`.
- Change: while isOnLayoutSpring, hitTest maps through `presentation()` of planned panes (O(changed)) and converts to
  the pane's rest coordinates; divider grabs wait for landing.
- Acceptance: Cmd-W at 50 %: a click drawn in pane B inside A's rest frame reaches B; no presentation() read without a
  spring.
- Test phase: every-action-sweep click-during-motion rows; hit test per event p99 <= 0.1 ms.
- Size M. Depends: 022a.

#### p03-rendering-099 HiddenFrameLRU
- Files: `.../CmuxNextHibernation/HiddenFrameLRU.swift` (new), `.../CmuxNextTerminal/TerminalFramePurgeability.swift`,
  `.../CmuxNextBrowser/CEF/CEFLayerHosting.swift`, `.../Tests/CmuxNextHibernationTests/HiddenFrameLRUTests.swift` (new).
- Change: app-wide LRU built in AppServices; locks for visible/capturing; soft count limit from physical memory;
  5 min cull with an injected Clock; purge of unlocked frames on memory-pressure warn.
- Acceptance: locked never evicted; oldest unlocked first; pressure purges all unlocked; no per-pane limit remains.
- Test phase: bench_memory.py 30 hidden tabs and terminals; show.again for the 4 most recent tabs.
- Size M.
- Gap (review of 099): pages are not in the list yet. A hosted page view is only a `CALayerHost` of the page
  window's remote context, and `setLayerHosting(false)` frees no Chromium surface, so evicting it freed nothing
  while it took slots from terminal frames that hold real IOSurfaces. Pages join when the fork has a call that
  drops a hidden widget's compositor surface (Chrome's `DelegatedFrameHost::EvictDelegatedFrame`), with a lock
  per page window, not per tab.

#### p03-rendering-100 Sidebar slide on the render server
- Files: `.../CmuxNextSidebar/Views/SidebarContainerView.swift`, `.../CmuxNextApp/WindowRootView.swift`,
  `.../CmuxNextBridge/ResizeCoordinator.swift`, `.../Tests/CmuxNextSidebarTests/SidebarSlideMotionTests.swift` (new).
- Change: set widthConstraint.constant once in the toggle's turn (one layout, one grid per terminal, one page
  resize); RenderSpring slides the sidebar panel layer (position.x) and the content host (additive position.x from
  the old offset to 0); fade variant on panel layer opacity; isWidthAnimating clears in the completion; watchdog
  stays. Registered as a MotionBackend kind.
- Acceptance: diff removes `Motion.animator(widthConstraint`; test: constant set once, layout passes = 1, grids per
  terminal = 1, completion once, gate off one frame; frame_sets frames 2..n = 0.
- Test phase: motion-main-work.py and motion-hitches.py sidebar-toggle light and STRESS: main p99 <= 0.5 ms, 0
  hitches; bench-terminal-resize.py reflows per toggle = 1.
- Size L. Depends: 001, 019, 020.

#### p03-rendering-101 Titlebar band reveal
- Files: `.../CmuxNextApp/Windows/CollapsedBandReveal.swift`, `.../CmuxNextApp/TitlebarView.swift`.
- Change: constant set once; band slides or clips by RenderSpring (bounds.size.width or a mask layer); start-from-
  what-shows by the additive model.
- Acceptance: `rg -n 'Motion.animator\(' .../CollapsedBandReveal.swift` = 0; open, close, open mid-flight: 1 layout per
  change, continuous presented width, completion once.
- Test phase: motion-main-work.py band-reveal; capture stills.
- Size S. Depends: 020.

#### p03-rendering-102 Toggle Omnibar without per-frame page resizes
- Files: `.../CmuxNextBrowser/UI/BrowserChromeView+Toolbar.swift`, `BrowserChromeView.swift`.
- Change: constant once (page resizes once); toolbar row slides and fades as a layer; page host additive position.y;
  gap shows page background.
- Acceptance: diff removes `Motion.animator(self.toolbarHeight` and the layoutSubtreeIfNeeded in the block; page
  resizes per toggle = 1 for both engines; completion hides toolbar once; gate off one frame.
- Test phase: pane-perf-terminal.py --browser omnibar-toggle: 0 hitches at 120 Hz.
- Size S. Depends: 020.

#### p03-rendering-103 Sidebar frame animators to SidebarDragSpring
- Files: `.../CmuxNextSidebar/Views/Sections/SidebarRegionView.swift`, `Priority/SidebarPriorityPanelView.swift`,
  `SidebarRowMotion.swift`, `SidebarGroupLineViews.swift`, `.../CmuxNextSidebar/Logic/SidebarLayout+Viewport.swift`.
- Change: route frame changes through `SidebarDragSpring.move(_:in:)`; scroll-to-row sets the clip origin once with an
  additive position spring on the document view layer.
- Acceptance: `rg -n 'animator\(\)\.(frame|setBoundsOrigin)' .../CmuxNextSidebar` only inside Motion.withoutAnimation;
  section reorder, priority change and scroll-to-row: frame_sets frames 2..n = 0; model frames = targets after the turn.
- Test phase: sidebar-motion-record.py; sidebar-churn-typing.py; motion-main-work.py sidebar-reorder.
- Size M. Depends: 001.

#### p03-rendering-104 MotionGate.animate: prove or remove per-frame writes
- Files: `.../CmuxNextDesign/Motion/Motion+AppKit.swift`, `MotionGate.swift`, `.../CmuxNextTabs/PaneToolbarView.swift`,
  `.../Tests/CmuxNextDesignTests/MotionGateMainWorkTests.swift` (new).
- Change: test counts main-thread writes per frame for `Motion.feedback.animate(.hover)` on alphaValue and frame. If
  writes happen per frame, MotionGate.animate(spring) adds RenderSpring layer animations for alpha and frame of
  layer-backed views; convert `PaneToolbarView.swift:179`.
- Acceptance: the commit states the before result; after: frame_sets and alpha writes per frame = 0 for spring
  tokens; motion-parity.py and check-motion.sh pass.
- Test phase: MotionGateMainWorkTests on 26 and 27; Tart 14 behavior (timed path).
- Size M. Depends: 001, 020. Queue: MQ-appkit-frame-animators.

#### p03-rendering-105 NSWindow/NSPanel animators
- Files: `.../CmuxNextDesign/HoverCards/HoverCardMotion.swift`, `.../CmuxNextFloating/ChiefPet/ChiefPetController.swift`,
  `.../CmuxNextFloating/QuickComposer/QuickComposerPanel+Floating.swift`, `.../CmuxNextDesign/Windows/WindowZoom.swift`,
  `.../CmuxNextBridge/ResizeCoordinator.swift`.
- Change: fades: panel alpha 1 once, content layer opacity animated (non-opaque, clear panel); window zoom and composer
  move hold grids and page resizes as full screen does, so content resizes once at the end.
- Acceptance: `rg -n '(panel|window|bubble)\??\.animator\(\)\.alphaValue' Packages/macOS/CmuxNext/Sources` = 0 outside
  Motion.withoutAnimation; hover-card fade window_calls = 0; window zoom grids per terminal = 1.
- Test phase: motion-main-work.py hover-card and window-zoom; capture stills of hover cards.
- Size M. Depends: 001. Queue: MQ-window-per-frame.

#### p03-rendering-106 ScreenContentView state and visibility from the plan
- Files: `.../CmuxNextLayout/Views/ScreenContentView.swift`, `ScreenContentView+Visibility.swift`, `LayoutRootView.swift`.
- Change: paneFrames and dividerFrames become rest rects plus an optional in-flight plan; at apply, visible/keepAlive =
  panes whose from or to rect meets the viewport; at landing narrow to rest; no per-frame updateVisibility.
- Acceptance: `rg -n 'AnimatedFrame|SpringValue'` in the two files = 0; Cmd-W and New Column: updateVisibility <= 2 per
  spring, panePresenceDidChange once per changed pane, an entering pane visible in the key's turn.
- Test phase: motion-main-work.py; pane-perf-terminal.py presence counts; split-no-flicker-e2e.py.
- Size M. Depends: 022a.

#### p03-rendering-107 Classify every FrameClient
- Files: `.../CmuxNextTabs/TabStripView+Layout.swift`, `.../CmuxNextSidebar/Views/SidebarDragAutoscroll.swift`,
  `SidebarMotionProbe.swift`, `.../CmuxNextBridge/ResizeCoordinator.swift`, `.../CmuxNextTerminal/TerminalFrameHold.swift`,
  `TerminalFinalGridTrace.swift`, `.../CmuxNextAgentPane/AgentPaneFrameClocks.swift`, `.../CmuxNextWakeups/ChatOpenTrace.swift`,
  `FrameBatchQueue.swift`, `.../CmuxNextDesign/Diagnostics/SwitchFrameTimer.swift`, `.../CmuxNextApp/Drag/TabDragSession.swift`,
  `scripts/cmux-next/render-done-checks.py`.
- Change: autoscroll clients get `// input-driven:` and `.motion` only while a drag sits in an edge zone; debug clients
  (debug.*, probes, traces) compile only under `DEBUG || CMUX_BENCH_HOOKS`; non-animation clients carry
  `// frame-client: <why>` and a rate class; candidates for VSyncHub are moved off main where they do no AppKit work.
- Acceptance: `render-done-checks.py --frameclients` = 0 unmarked; no debug client symbol in a Release `nm`; no
  isAnimation client active during a Cmd-D spring with the tunable on.
- Test phase: render-done-checks.py; bench_idle.py not worse.
- Size S. Depends: 013, 005.

#### p03-rendering-108 shadowPath on shadowed layers
- Files: the 11 MQ-shadow-path files (`CmuxNextTabs/TabCell.swift`, `Groups/TabGroupChipCell.swift`,
  `CmuxNextLayout/Views/PaneOverlayView+Glow.swift`, `CmuxNextAgentCursor/AgentCursorLayer.swift`,
  `CmuxNextApp/Drag/TabDragGhostPanel.swift`, `CmuxNextDesign/Palette.swift`, `Motion/Motion+Launch.swift`,
  `Motion/Motion+Attention.swift`, `CmuxNextMacScreen/MacScreenButtons.swift`, `CmuxNextSidebar/Views/SidebarUpdateToggle.swift`,
  `CmuxNextBrowser/PageInfo/UI/PageInfoToggle.swift`).
- Change: shadowPath from the shape's rounded rect, recomputed only on bounds or radius change; text-shaped shadows get
  `// shadow: alpha-derived <why>`. A shadowPath on a layer that springs gets its own path animation from the plan.
- Acceptance: MQ-shadow-path empty; each assignment behind a change check; capture stills match.
- Test phase: motion-hitches.py tabs and panes not worse; Quartz Debug offscreen flash count over Cmd-D = 0.
- Size S.

#### p03-rendering-109 .inVisibleRect tracking areas added once
- Files: the 39 MQ-tracking-areas files.
- Change: add the area once (init or viewDidMoveToWindow) and delete the override; keep it only where options change
  with state, with a comment.
- Acceptance: MQ-tracking-areas lists only annotated files; PointerHover and divider hover tests pass.
- Test phase: bench-terminal-resize.py and a window live resize: addTrackingArea per frame = 0; hover e2e on tabs,
  rows, dividers.
- Size M (split by package if over 400 lines). Depends: 001.

#### p03-rendering-110 Responsive scrolling
- Files: `.../CmuxNextSidebar/Views/SidebarScrollView.swift`, `SidebarView.swift`, `.../CmuxNextPalette/PaletteListView.swift`,
  `.../CmuxNextTerminal/TerminalScroller.swift`.
- Change: `isCompatibleWithResponsiveScrolling` true where the scrollWheel override only diverts horizontal gestures;
  observers move to the clip view hook; TerminalScroller stays on main with a reason if it drives the viewport per event.
- Acceptance: SidebarScrollView and PaletteListView return true; a 50 ms main stall during momentum scroll still
  advances the clip origin (test); profile-swipe tests pass.
- Test phase: sidebar-perf-validate.py scroll with script-storm-bench.py running: drops lower at 120 Hz.
- Size M. Depends: 039.

#### p03-rendering-111 No Auto Layout: pane content and window root
- Files: `.../CmuxNextApp/PaneContentView+Band.swift`, `PaneContentView+Toolbar.swift`, `Screens/WorkspaceContentView.swift`,
  `WindowRootView.swift`, `TitlebarView.swift`, `EmptyWorkspaceView.swift`.
- Change: frame layout in layout() from a pure function of bounds and metrics.
- Acceptance: no `translatesAutoresizingMaskIntoConstraints = false` in these files; tests for sidebar left, right,
  hidden, titlebar shown/hidden, band and toolbar widths; capture stills match.
- Test phase: window-live-resize-bench.py; cmux-ci capture light and dark.
- Size L. Depends: 100.

#### p03-rendering-112 draw(_:) overrides to layer properties
- Files: `.../CmuxNextPalette/PaletteRowCell.swift`, `PaletteChromeViews.swift`, `PaletteActionsMenuView.swift`,
  `.../CmuxNextDesign/Overlay/PopupRowView.swift`, `.../CmuxNextSidebar/Views/SidebarRailView.swift`, `ProfileBarView.swift`,
  `ProfileBarView+Marks.swift`, `Sections/SidebarAvatarView.swift`, `.../CmuxNextFocusUI/WhichKey/WhichKeyOverlay.swift`,
  `.../CmuxNextBrowser/CEF/CEFDevToolsDivider.swift`, and TitlebarDragBlocker (delete the empty draw).
- Change: fills, borders and selection as layer properties with updateLayer and `.onSetNeedsDisplay`; text stays
  ChromeLabel.
- Acceptance: MQ-draw lists only views named in the PR with a reason (ChromeLabel fallback, UIInspector, screenshot
  overlay); capture stills of palette, popups, sidebar match.
- Test phase: bench-typing.py palette rows not worse; damage_area per selection move lower.
- Size M. Depends: 001.

#### p03-rendering-113 Occlusion readers onto WindowOcclusionFamily
- Files: `.../CmuxNextWakeups/WindowOcclusionFamily.swift` and the 27 MQ-occlusion files (including
  `CmuxNextApp/SurfaceInvariantMonitor.swift`, which observes with `object: nil`).
- Change: each reader subscribes to the family (P3); no direct NotificationCenter or occlusionState read.
- Acceptance: `rg -n 'didChangeOcclusionStateNotification' Packages/macOS/CmuxNext/Sources` hits only
  WindowOcclusionFamily.swift and Debug* files; a fake signal reaches each subscriber of that window once and none of
  another window.
- Test phase: bench_idle.py covered-window; occluded-window e2e for terminals and BackdropVideoView.
- Size M (split by package if over 400 lines). Depends: 097.

#### p03-rendering-114 Phone and RemoteView producers off main
- Files: `.../CmuxNextPhone/Live/PhoneScreenView.swift`, `.../CmuxNextPhone/PhoneTabView.swift`,
  `.../CmuxNextRemoteView/Present/LayerContentsPresenter.swift`.
- Change: MetalFramePresenter pattern (CAMetalLayer, `presentsWithTransaction = false`) or the 017 form; only a size
  change hops to main, coalesced per frame; layer retained until the producer stops.
- Acceptance: no per-frame contents set from a @MainActor method; fake 60 fps source: main hops = size changes;
  teardown test.
- Test phase: Phone live and RemoteView at 60 fps: main turns from these owners <= 1/s.
- Size S. Queue: MQ-producer-main-hops.

#### p03-rendering-115 Window live resize bench and O(changed) path
- Files: `scripts/cmux-next/window-live-resize-bench.py` (new), `.../CmuxNextLayout/Views/ScreenContentView.swift`,
  `LayoutRootView.swift`, `scripts/cmux-next/perf-hot-benches.json`.
- Change: bench drives a live resize (AX window drag at 120 Hz on --vdisplay) and full screen enter/exit, STRESS 4x3
  with Chromium; reports main ms per event, layout() calls, grids per frame, page resize waits. Then the per-event
  path does a pure geometry recompute and frame sets only for changed panes, with no model reconcile
  (`ScreenContentView.swift:120` reconcileAndScroll).
- Acceptance: records host, OS, refresh rate; exits non-zero on a wrong session shape; 1 pt width change of 12 panes
  sets frames only on changed panes, 0 reconciles.
- Test phase: base and head on 26 and 27 (DC16).
- Size M. Depends: 001.

#### p03-rendering-116 CEF pump slices respect the frame deadline
- Files: `.../CmuxNextBrowser/CEF/CEFMessagePump.swift`, `CEFPumpSchedule.swift`, `CEFSwitches.swift`, fork
  `libcef/browser/browser_message_loop.cc` (per-call slice), `CEFShim/src/shim_windows.mm`.
- Change: the fork's static `--cmux-pump-time-slice-us=2000` (fork 066b083f) becomes a per-call slice
  `cmux_set_message_loop_time_slice(us)`; cmux passes targetTimestamp - now - measured main commit (015), floor
  1 ms; no slice starts inside an input turn or a plan apply; pending input preempts the follow-up. Until F2 moves the
  pump off main. Coordinate with PL-cefhost.
- Acceptance: CEFPumpSchedule fake-clock tests: no slice crosses the deadline; skipped while input pending; older fork
  falls back to the static switch; fork test bounds MessagePumpExternal.
- Test phase: bench-typing.py omnibar and terminal with a busy page STRESS: p99 <= 16.7 ms; motion-hitches.py with
  pages loading: hitches lower.
- Size M. Depends: 012, 015, 041.

#### p03-rendering-117 Low Power and thermal frame-rate caps
- Files: `.../CmuxNextWakeups/DisplayClock.swift`, `FrameClient.swift`, `.../Tests/CmuxNextWakeupsTests/DisplayClockTests.swift`.
- Change: injected PowerState seam: in Low Power Mode or serious thermal state `.ambient` pauses (LoopVisibility),
  `.ui` caps at 60, `.motion` unchanged.
- Acceptance: fake PowerState tests for the three classes.
- Test phase: bench_power.py Low Power Mode on: power lower.
- Size S. Depends: 013, 070.

#### p03-rendering-118 Link and workspace drag ghosts in-window
- Files: `.../CmuxNextTabs/Drag/LinkDragGhost.swift`, `.../CmuxNextApp/Drag/TabDragSession+Ghost.swift`,
  `TabDragSession+Workspaces.swift`.
- Change: as task 035.
- Acceptance: window_calls during in-window link or workspace drag = 0; drag tests pass.
- Test phase: drag-lag-live.py link and workspace drags.
- Size S. Depends: 035.

#### p03-rendering-119 Ghostty wakeup_cb ticks frame-coalesced
- Files: `.../CmuxNextTerminal/GhosttyRuntime.swift`, `GhosttyRuntimeCallbacks.swift`.
- Change: register `GhosttyRuntime.tick` as a debug.wakeups owner; while output streams coalesce ticks to one per
  display frame (FrameBatchQueue); clipboard confirm and close stay immediate.
- Acceptance: fake 10,000/s wakeups give at most one tick per fake frame; owner listed; DC6 includes it.
- Test phase: DC6 run.
- Size S. Queue: MQ-ghostty-main-hops.

#### p03-rendering-120 App web pages stop loops when hidden
- Files: `webviews/src/pages/shared/desktop.css`, `webviews/src/ui/wave.css`, `webviews/src/styles.css`, the WebTheme
  motion bootstrap that sets `data-cmux-motion`, `webviews/test/hidden-page-no-frames.test.ts` (new).
- Change: bootstrap adds `[data-cmux-hidden] *{animation-play-state:paused}`, set from visibilitychange and the native
  visibility push (as AgentPaneFramePacer); rAF loops check a shared `framesAllowed()` guard.
- Acceptance: test: hidden page has 0 running animations (`document.getAnimations()`) and 0 rAF callbacks over 1 s;
  `bun run check` and `scripts/web-lint.sh` pass; the test is not added to a CI lane.
- Test phase: render-idle-damage.py with WebContent wakeups: hidden app pages 0/s.
- Size M. Depends: 003. Queue: MQ-web-loops.

#### p03-rendering-121 Off-main image decode
- Files: the 19 MQ-image-decode sites on main-actor paths (for example
  `CmuxNextHome/NewMessage/HomeRecipientAvatarView.swift:61`, `CmuxNextBrowser/UI/ExtensionActionButton.swift:73`,
  `CmuxNextBrowser/UI/ExtensionsMenu/ExtensionIconCache.swift:27`), `.../CmuxNextIcons/IconAssets/IconAssetDecode.swift`.
- Change: decode on a utility task with `CGImageSourceCreateThumbnailAtIndex` and
  `kCGImageSourceShouldCacheImmediately = true` at the target pixel size; IconAssetDecode stays the one decoder,
  immediate for layer-bound uses.
- Acceptance: MQ-image-decode hits on @MainActor paths = 0 or annotated; a 512 px PNG decoded through the path does no
  decode on main (test).
- Test phase: sidebar and extension-menu open benches not worse; Time Profiler shows no ImageIO decode on main.
- Size M. Queue: MQ-image-decode.

## 9. Order for the 72 h

- Hour 0, in parallel: 041 + 044 + 058 (fork builds), 016, 017, 019, 020, 021, 010, 007, 001, 005, 006, 066, 079,
  088, 089, 099, the hour-0 R2 decision.
- Day 1: 022a, 014, 012, 013, 042, 080, 082, 097, 100, 060/061, 108, 109, 038, 039, 075, 121, 114, 119.
- Day 2: 022b, 023-035, 106, 098, 036, 043, 050, 081, 083, 084, 093, 090, 091, 101-105, 107, 110, 113, 115, 116, 003,
  062-065, 067-069, 070, 071-074, 085-087, 092, 117, 118, 120.
- Day 3: 022c (after DC2/DC2t/DC3/DC4 and the F4 record), 045, 046, 051-056, 096, 111, 112, done checks on the tip.
