# cmux-next rendering: one frame clock, render-server motion, pages as layers

Status: design (2026-10-25). Owner: the Performance Lead, with the area owners in "Owners" below. Program spec, task
table and per-task acceptance: [chrome-parity/p03-rendering.md](chrome-parity/p03-rendering.md). This page keeps
the rules R1-R7, the Chrome file that each rule copies, and the written reasons where cmux does not copy Chrome.
Patterns: [PATTERNS.md](PATTERNS.md) P6, P6a, P7, P8, P8a, P10a, P10b. Threads: [threading-model.md](threading-model.md)
("VSyncHub" and "Renderer QoS").

## Goal

The main thread calculates geometry once for each change and commits it. The render server animates it. Each
content producer renders on its own thread at the vsync of its display. No main-thread work runs for each
animation frame. No view or layer is invalidated unless a value changed.

This removes design fault F4 (motion is a live resize of real frames on every frame) and F1 (Chromium pages are
child windows), with the render half of ghostty-integration-DESIGN G1, G4, G6 and G7 ([perf-lead.md](perf-lead.md)
section 3).

## Rules

Chromium paths are in `chromium/src` at HEAD (read 2026-10-25).

### R1 One frame clock for each display

| cmux | Chrome |
|---|---|
| `CmuxNextWakeups/DisplayClock.swift` owns the only display link for each `CGDirectDisplayID`. Every `FrameScheduler` (window, app, budgeted) subscribes to the clock of its display. A window moves to the new clock on `didChangeScreen`. | `ui/display/mac/display_link_mac.h`: `DisplayLinkMac::GetForDisplay(display_id)` gives one shared link for each display. |
| The link runs on the `VSyncHub` thread of its display (user-interactive). Off-main producers get the callback on that thread. Main subscribers get one coalesced post to main, with at most one post pending. | `display_link_mac.mm` posts each tick to the thread that registered the callback (`base::BindPostTaskToCurrentDefault`). |
| Each `FrameTick` carries `timestamp`, `targetTimestamp` (the deadline), `interval` and `sequence`. | `components/viz/common/frame_sinks/begin_frame_args.h`: frame_time, deadline, interval, sequence. |
| The link runs only while a client is armed, at the highest rate that an armed client asks for: motion 120 Hz, UI 60 Hz, ambient 30 Hz. Low Power Mode and thermal state set a cap. | `components/viz/service/display/frame_rate_decider.h`; battery saver in `components/performance_manager`. |
| `MainFrameBudget` stops budgeted work at `targetTimestamp` minus the measured p95 of the main CA commit and layout. The in-process CEF pump slices to the same deadline. | `cc/scheduler/scheduler.h`: the frame does not wait for a slow main thread. |

Where cmux is different: Chrome has one link for each display (`DisplayLinkMac::GetForDisplay`). cmux keeps that
unless task p03-rendering-014 measures a p99 rise of 0.1 ms or more from the hop to main. Then cmux has two links for
each display (one on main, one on the hub), and task 014 records why (difference 6 below).

### R2 Commit once, animate on the render server

| cmux | Chrome |
|---|---|
| A structural change (split, close, zoom, New Column, workspace switch) makes a `PaneMotionPlan` in the turn of the key: a pure value with the from and to rects of each changed pane, divider, camera and pane-chrome sublayer. Its cost is O(changed). | `cc/trees/layer_tree_host.h`: the main thread commits one tree; the compositor animates it. |
| Main sets each `NSView` frame to its rest value once, lays out once, then adds `RenderSpring` animations. A retarget adds a new additive spring from (old model - new model) to 0. The running springs keep the velocity. | `cc/animation/animation_host.h`, `keyframe_model.h`: compositor animations of transform, opacity and filter. |
| Animations go on a motion container layer for each pane, never on a backing layer that AppKit writes again (spike task 016 selects the layer). Each chrome sublayer that does not scale (ring, glow, dim, border, edge items) gets its own spring with the same token and `beginTime`. | No equivalent: see the first difference below. |
| The animation lands in a `CATransaction` completion. No `FrameClient` ticks during a structural spring. Hit testing during a spring uses `layer.presentation()` of the panes that move. | `cc/input/input_handler.h` hit-tests on the compositor tree. |
| Gestures stay O(1) for each input event: a strip pan sets one property of the motion container. A fling is a `RenderSpring` with the release velocity. | `cc/input/input_handler.h`: threaded scrolling. |
| Content: terminals get their final grid in the turn of the key and keep rest-size content during the spring (ghostty-integration-DESIGN 4d). Pages resize once at spring start, in one CA fence for all resized pages (deadline 2 frames). The page background fills the gap. | `cc/layers/deadline_policy.h` and `components/viz/service/surfaces/surface.h` (surface sync with a deadline); `content/browser/renderer_host/delegated_frame_host.h` (gutter color). |

R2 ships behind the Tunable `motion.renderServer`, default off. Task 022c turns it on only after it records the
decision for Lawrence, with the measured reason and a capture of Cmd-D and Cmd-W with a Chromium pane (spec
section 3, "Recorded decision"). Until then, the per-frame live resize of F4 is the default.

### R3 Chromium pages are layers, with input in the same NSView

| cmux | Chrome |
|---|---|
| Track A: a fork pin with API 27 or later and fence resize; page visibility from the embedder; layer hosting on by default (`CEFHostedPageView`, `CEFLayerHosting`) with the transparent input window of API 26 and 27; show and hide in the transaction of the switch. | `ui/accelerated_widget_mac/display_ca_layer_tree.h`: GPU output through a `CALayerHost` on the `CAContext` of the GPU process (`GotCALayerFrame`). |
| Track B: the fork attaches the `RenderWidgetHostViewCocoa` of the page as a child of `CEFHostView`. Pixels, input, IME, cursor, drag, popups and accessibility then come from the Cocoa view of Chromium. The page window never orders in. | `content/app_shim_remote_cocoa/render_widget_host_ns_view_bridge.h`: "the NSView used for input and display"; `render_widget_host_view_mac.h` `MigrateNSViewBridge`. |
| Resize never blocks main: the fence port (`-[CAContext setFencePort:]`) makes the render server wait. No pin bump can add the post-commit wait again (task 041). | `ui/accelerated_widget_mac/ca_transaction_observer.h`: `CATransactionCoordinator` pumps the UI thread up to 500 ms before and 50 ms after the commit. cmux does not copy this wait. |
| All child-window fallback code goes into one file, `CmuxNextBrowser/CEF/ChildWindowPageFallback.swift`. | Chrome has no child-window pages. |

### R4 Damage and invalidation

| cmux | Chrome |
|---|---|
| `RenderStats` (armed only, Debug and bench builds) counts for each display frame and owner: view frame sets, `layout()` calls, `updateLayer` and `draw` calls with their area, contents sets, window-server calls and tracking-area adds. Timed passes run with it disarmed. | `cc/trees/damage_tracker.h`, `components/viz/service/display/display_damage_tracker.h`. |
| Each invalidation has a changed value or `// invalidate: <why>`. Each forced sync layout or flush has `// sync-layout: <why>` (pre-push guardrail). Layer-backed views set `.onSetNeedsDisplay` or `.never` with stretch-safe contents. | `ui/accelerated_widget_mac/ca_renderer_layer_tree.h`: `CommitScheduledCALayers` changes only the layers that changed. |
| Shadows have a `shadowPath`. `.inVisibleRect` tracking areas are added once. Images bound to layers are decoded off main. | `cc/tiles/image_controller.h`: image decode off main. |
| Ghostty draws no frame when nothing is dirty and redraws only the rows that changed since that buffer was last used. The cursor blinks on the render server. Idle target: 0 damage rects/s. | `cc/tiles/tile_manager.h`; partial swap. |

Cleanup follows the measured damage owners (`render-idle-damage.py`, task 003), not a rewrite of every site.

### R5 Producers present off main

| cmux | Chrome |
|---|---|
| Spike task 017 selects the form for Ghostty: a `CAMetalLayer` for each surface that presents on the renderer thread (`presentsWithTransaction = false`, the in-tree `CmuxNextRemoteView/Present/MetalFramePresenter.swift`), or a `CAContext` for each renderer shown through a `CALayerHost`. See "Spike 017" below. | `gpu/ipc/service/image_transport_surface_overlay_mac.h`: the GPU process commits its own context. |
| The renderer is the only writer of the presented contents. Main hides, shows and purges through a Ghostty API. A path with two writers uses a monotonic frame sequence, so an old frame never replaces a newer one. | One producer for each surface (`components/viz/service/surfaces/surface.h`). |
| External vsync from `VSyncHub` replaces the `CVDisplayLink` of each surface. Only dirty, visible surfaces arm. `wakeup_cb` ticks coalesce to one for each frame. | `components/viz/service/frame_sinks/external_begin_frame_source_mac.h`. |

Rejected: a `CATransaction` on the renderer thread into a layer of the tree that main owns. It causes lock
contention with the main commit, priority inversion and a teardown race (rule 5 in section 4).

#### Spike 017: Ghostty present form

Prototype: ghostty-next branch `cp/p03-rendering-017`. The Ghostty config key `macos-present-form` selects the
form when the surface is made; the default `main-contents` is the shipped path. Files:
`src/renderer/metal/OffMainPresenter.zig` (both off-main forms), `src/renderer/Metal.zig` and
`src/renderer/metal/Frame.zig` (the hooks), `src/renderer/metal/IOSurfaceLayer.zig` (the overlay generation),
`src/renderer/metal/PresentHistogram.zig` (the wait histogram).

| Form | What the renderer does for each frame | Main thread |
|---|---|---|
| `main-contents` (shipped) | Sets the frame as the contents of `IOSurfaceLayer` through `dispatch_async` to main | One turn for each frame |
| (a) `metal-layer` | Copies the frame into a drawable of a `CAMetalLayer` and calls `presentDrawable:` on the command buffer (`presentsWithTransaction = false`). No CA transaction. | No turn for each frame |
| (b) `layer-host` | Sets the frame as the contents of the root layer of its own `CAContext`, in a transaction that it commits; a `CALayerHost` under a flipped layer shows that context (Chrome: `gpu/ipc/service/image_transport_surface_overlay_mac.h`, `ui/accelerated_widget_mac/display_ca_layer_tree.h`) | No turn for each frame |

Both off-main forms use the same main-thread rule:
- The off-main layer (the overlay) is a sublayer of `IOSurfaceLayer`. Main writes the overlay (`hidden`,
  `drawableSize`, `contentsScale`); the renderer writes only drawables (a) or its own context (b).
- A frame for a new size is still presented by main in its own transaction (the resize pre-commit of G1,
  `presentHostSized`). That present hides the overlay and starts a new overlay generation.
- The first frame that the renderer encodes after the hide posts one reveal of that generation. The reveal shows
  the overlay and clears the root contents. A reveal of an older generation does nothing, so the overlay never
  comes back with a frame older than the one that main presented. Cost: one main turn for each resize, not for
  each frame.

Measure: `scripts/cmux-next/ghostty-present-form-bench.py --app APP --out OUT --vdisplay 120` on a fleet GUI mini,
with a cmux build that embeds the spike branch. It runs 10 terminals with `yes` in each form and records main time
for each frame and missed frames (`debug.frames`), xctrace Animation Hitches and commit times, Ghostty frames, one
resize, and the teardown of the 10 terminals while `yes` writes. Each renderer logs its counters when it is freed
(os_log category `present_form`): frames sent to main, frames shown off main, refused frames, main presents,
reveals, and the off-main wait (a: `nextDrawable`; b: the commit of the renderer's own transaction, the signal for
lock contention with the main commit).

| 10 `yes` terminals, 120 Hz | `main-contents` | (a) `metal-layer` | (b) `layer-host` |
|---|---|---|---|
| Main turns for each Ghostty frame (`main_hops_per_frame`) | not measured | not measured | not measured |
| Main time for each display frame p95 (ms) | not measured | not measured | not measured |
| Main CA commit p95 (ms, hitches-updates) | not measured | not measured | not measured |
| Hitches in 3 x 10 s | not measured | not measured | not measured |
| Off-main wait p50 / p95 / max (us) | - | not measured | not measured |
| Teardown with `yes` running: app answers, renderers logged | not measured | not measured | not measured |

Status: the numbers are not recorded. The spike branch was written on a Linux host, where Ghostty's macOS renderer
does not compile and no app can run. The next fleet round must run `zig build test` on the spike branch and the bench
above, and put the numbers in this table.

Choice (provisional until the table has numbers): (a) `metal-layer`.
- It is public API with no SPI (risk 11 in section 4), and it is the in-tree pattern
  (`CmuxNextRemoteView/Present/MetalFramePresenter.swift`).
- A drawable present has no CA transaction at all, so it cannot contend with the main commit. Form (b) still
  commits a transaction on the renderer thread, in its own context.
- It gives a true presented time (`addPresentedHandler:`), which difference 5 below needs for Ghostty.
- The chosen form has no CATransaction off main into a layer that an `NSView` owns: the renderer calls only
  `nextDrawable` and `presentDrawable:` and sets no layer property.
- Teardown: `Metal` keeps its reference to the overlay until `Metal.deinit`, which runs after the renderer thread
  stopped and its frames completed. A frame in flight holds its drawable, and the drawable holds the layer.
- (b) replaces (a) if the bench shows a p99 `nextDrawable` wait over 2 ms, or more hitches than `main-contents`.

Costs of (a) that task 080 must remove before it ships:
- One copy for each frame and 3 drawables for each surface, next to the 3 IOSurfaces of the swap chain. Task 080
  draws into the drawable and keeps an IOSurface only for the resize frame. Measure the bytes with `bench_memory.py`.
- `nextDrawable` runs under the renderer's draw mutex, and a main-thread synchronous draw (the first frame) takes the
  same mutex. Task 080 gets the drawable before it takes the mutex.
- The reveal is a `dispatch_async` to main. Task 080 moves it into the display pass of the embedder, so that no
  Ghostty code posts work to main.

### R6 Hidden and occluded cost nothing

| cmux | Chrome |
|---|---|
| The switch hides a workspace root (`isHidden`) in its own turn; it does not detach it. Content is evicted as a separate step. Detach occurs only after the grace, as budgeted idle work, and only if a measurement shows that it pays. | `content/browser/renderer_host/render_widget_host_view_mac.mm` (`WasOccluded`, `Hide`): the view is hidden and the `NSView` stays attached; `content/browser/renderer_host/delegated_frame_host.cc` (`EvictDelegatedFrame`): the frame is evicted as a separate step. |
| One `WindowOcclusionFamily` for each window. It adds the same-size window check, because the system occlusion state fails for windows of similar size. Every reader subscribes to it. | `content/app_shim_remote_cocoa/web_contents_occlusion_checker_mac.h` (crbug.com/883031). |
| One app-wide `HiddenFrameLRU` for page frames and terminal last frames: locks for visible frames, a soft limit from physical memory, a 5 min cull, a purge on memory pressure. | `components/viz/client/frame_eviction_manager.h`. |
| App web pages stop infinite CSS animations and `requestAnimationFrame` loops when hidden or occluded. | `content/browser/renderer_host/render_widget_host_impl.cc` (`WasHidden`) and `cc/scheduler/scheduler.cc`: a hidden renderer stops its BeginFrames and produces no frames. |

### R7 Measurement

No CI gates (Lawrence 2026-10-23). Agents run these tools on the fleet.

| cmux | Chrome |
|---|---|
| Time: `motion-hitches.py` (xctrace Animation Hitches, a Time Profiler of main, and a ScreenCaptureKit timeline from a separate process) at `--vdisplay=120`. No `FrameClient` runs in the app during a timed pass. | `cc/metrics/dropped_frame_counter.h`, `frame_sequence_tracker.h`. |
| Counts: `motion-main-work.py` with `RenderStats` armed. A counting pass reports no milliseconds. | No equivalent: Chrome counts frames in viz (`cc/metrics/frame_sequence_metrics.h`), not main-thread work items. |
| Release field data: `motion.late_commits` and `action.presented_estimate` (the `targetTimestamp` of the first tick after the commit), with no display link started for them. `action.presented` only where a true presented time exists. | `cc/metrics/event_metrics.h`: EventLatency ends at the presentation timestamp. |
| Distributions p50, p95, p99 and max; light and STRESS; macOS 26 and 27. Tart VMs on 14 and 15 prove behavior only. | UMA histograms. |

## Where cmux is different from Chrome, and why

1. **Bounds and position animate on the render server.** In Chrome Views, only `ThreadedTransformTransition` and
   `ThreadedOpacityTransition` run on the compositor (`ui/compositor/layer_animation_element.cc`).
   `BoundsTransition`, `ClipRectTransition` and `RoundedCornersTransition` step on the main thread, and
   `BoundsAnimator` sets the View bounds on main for each frame. cmux panes change size during a split or close,
   so the Chrome model puts a layout on main for each frame. At 30 panes that costs 41 ms for each frame
   (perf-lead F4). Core Animation can animate `bounds` and `position` on the render server, so cmux does that.
   The costs, and where each one is paid:
   - Sublayer layout does not follow an animated bound: CA applies `autoresizingMask` at commit, for the model
     value. Each dependent sublayer gets its own spring (task 029). DC4 checks each edge within 0.5 pt.
   - Drawn geometry and `NSView` geometry differ for up to 240 ms. Hit testing goes through the presentation
     tree (task 098). Tracking areas and cursor rects refresh at landing.
   - Content cannot lay out at each frame size without main work. Terminals hold rest-size content (4d); pages
     resize once in a fence. This is the F4 decision that task 022c records.
2. **One `CAContext` for each page, while cmux chrome is AppKit.** In Chrome a tab draws through the compositor
   of its window (`content/browser/renderer_host/browser_compositor_view_mac.h`), and viz aggregates page and
   browser UI into one frame (`components/viz/service/display/surface_aggregator.h`). The cmux chrome is AppKit
   layers, not a viz client, so viz cannot aggregate it. Each hosted page keeps its own `CAContext`, shown through
   one `CALayerHost`, and the render server composites it with the chrome. Each visible page pays its own GPU
   memory (its swap-chain IOSurfaces) and its own BeginFrame source.
   - GPU memory for each hosted page (IOSurface and GPU bytes, `bench_memory.py`): not measured.
   - BeginFrame cost for each visible page (wakeups, `bench_idle.py`): not measured.
   - Task p03-rendering-050 owns both measurements. Its acceptance and test phase require it to record the numbers
     here before layer hosting is on by default.
   - Limits: a hidden page stops BeginFrames through embedder visibility (task 058) and
     `WindowOcclusionFamily`; its frame goes into `HiddenFrameLRU` (task 099; pages use it from task 054). So the
     cost grows with visible pages, not with open pages.
3. **No blocking resize wait.** Chrome pumps the UI thread up to 500 ms in pre-commit
   (`ca_transaction_observer.h`, `kUIPaintTimeout`). cmux uses the fence port instead: the render server waits
   for the page, the main thread does not (DC9: main wait for each commit p99 = 0.0 ms).
4. **Track A input window.** Until Track B lands, a transparent page window stays over the host view for input.
   Chrome never forwards input from another window. Track B removes this difference; if Track B misses the
   72 h push, Track A ships alone and the deletions 051-053 wait.
5. **Measurement from outside the process.** Chrome counts dropped frames in viz, from BeginFrame sequence
   numbers and `gfx::PresentationFeedback`. AppKit gives no presentation feedback for layers that the render
   server animates. So timing comes from xctrace and a separate-process capture, and the Release number is an
   estimate. A true presented time exists only where a producer presents its own drawable (Ghostty after task
   080, `MetalFramePresenter`).
6. **Two display links for each display, only if the hop to main is measured as too slow.** Chrome has one link
   for each display and posts each tick to the thread that registered (`ui/display/mac/display_link_mac.mm`).
   cmux does the same by default: the `VSyncHub` thread holds the link and posts one coalesced tick to main.
   If task p03-rendering-014 measures a p99 rise of 0.1 ms or more in the main tick latency from that hop, cmux
   adds a second link on main for each display, and task 014 records the numbers and the reason here. No
   measurement is recorded yet, so the default is one link.

## Done checks

`scripts/cmux-next/render-done-checks.py` (task 005) runs the query parts. The full queries and thresholds are in
spec section 5.

| Check | What it proves | Tool |
|---|---|---|
| DC1 | One display link for each display with an armed subscriber; 0 at idle | rg, `debug.wakeups` |
| DC2 | Render-server motion: frames 2..n make 0 view frame sets and 0 `layout()` calls | `motion-main-work.py` |
| DC2t | Main work for each spring frame p99 <= 0.5 ms | `motion-hitches.py` |
| DC3 | 0 hitches in each DC2 scenario, light and STRESS, 3 rounds | `motion-hitches.py` |
| DC4 | Spring parity <= 0.25 pt; sublayer edges within 0.5 pt | RenderSpringParityTests, PaneSublayerParityTests |
| DC5 | Key to frame p50 <= 8.3 ms, p99 <= 16.7 ms at 120 Hz | `bench-typing.py`, `typing-frame-bench.py` |
| DC6 | Ghostty presents 0 frames through main | `debug.terminal_display` |
| DC7r | Idle render wakeups and damage = 0 | `bench_idle.py`, `render-idle-damage.py` |
| DC8a, DC8b | Pages are layers (Track A), then views (Track B) | `cef-layer-verify.py`, `debug.layers` |
| DC9 | Resize never blocks main | `cef-resize-sync-bench.py` |
| DC10 | Switch with Chromium: input to commit p95 < 8.3 ms | `cef-layer-ab.py` |
| DC11 | Each forced sync layout has `// sync-layout:` | rg, guardrails.py |
| DC12 | Hidden workspaces hold 0 render bytes outside `HiddenFrameLRU` | `bench_memory.py` |
| DC13 | 0 per-frame window-server calls from cmux in motion | `RenderStats` |
| DC14 | `action.presented_estimate` p95 error <= 1 frame | `perf-signposts.py` |
| DC15 | Launch, split and a hosted page on macOS 14 and 15 (behavior only) | `os-matrix.sh` |
| DC16 | Window live resize: main for each event p99 <= 4 ms | `window-live-resize-bench.py` |

## Machine queues

Each queue is an rg query over `Packages/macOS/CmuxNext/Sources` (spec section 6 has the exact query and the base
count). A queue is done when its query gives 0 hits or only annotated hits.

| Queue | Removes | Tasks |
|---|---|---|
| MQ-displaylinks | display links outside DisplayClock and VSyncHub | 010, 014, 082, 083 |
| MQ-springs | CPU springs stepped on main | 019-033, 106 |
| MQ-appkit-frame-animators | AppKit frame and constraint animators | 100-104 |
| MQ-frameclients | unclassified `FrameClient` sites | 107 |
| MQ-sync-layout | forced sync layouts without a reason | 066-069 |
| MQ-damage-owners | measured owners of idle damage and motion layouts | 062-065 |
| MQ-redraw-policy | `updateLayer` overrides without a redraw policy | 060, 061 |
| MQ-frame-observers | frame and bounds observers that run in motion | 037-039, 110 |
| MQ-loops | infinite CA animations that run when hidden | 013, 070 |
| MQ-child-window-pages | child-window page code outside the fallback file | 051-053, 056 |
| MQ-window-per-frame | per-frame `NSWindow` alpha and frame sets | 034, 035, 105, 118 |
| MQ-pane-autolayout | Auto Layout in pane and window chrome | 071-073, 111 |
| MQ-ghostty-main-hops | Ghostty frames that hop to main | 080, 081, 084, 093, 119 |
| MQ-producer-main-hops | other producers that set contents on main | 114 |
| MQ-labels | label glyph caches | 075 |
| MQ-shadow-path, MQ-tracking-areas, MQ-draw | shadows without a path; tracking areas added again; `draw(_:)` overrides | 108, 109, 112 |
| MQ-occlusion | occlusion readers outside `WindowOcclusionFamily` | 113 |
| MQ-image-decode | image decode on main | 121 |
| MQ-web-loops | CSS and rAF loops in app web pages | 120 |

## Owners

Tell the [OWNERS.md](OWNERS.md) owner before you edit an owned file: PL-motion-core (`ScreenContentView+Motion*`,
`Dock*`, `LayoutRootView*`, `PaneHostView`, `DisplayLinkDriver`), PL-motion-cef (`WindowOverlayLayer`,
`WindowOverlayHost*`, `DividerMouseCatchers`), PL-cef-layer (`CEFHostView*`, `CEFClipShape`, `Shim/`), PL-ghostty
(`CmuxNextTerminal`, `ghostty-next`), PL-typing (`HomeComposer`, `TypingLatencyProbe`), PL-switch (`WindowState`,
`WindowController`), PL-guardrails (`guardrails.py`, `perf-hot-benches.json`), the Performance Lead
(`CmuxNextWakeups`, `CmuxNextDesign/Motion`).
