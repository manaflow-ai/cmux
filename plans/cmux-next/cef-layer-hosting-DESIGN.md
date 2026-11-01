# Chromium pages in the cmux window's layer tree (layer hosting)

Status: slice 1 in progress (2026-10-23, PL-cef-layer). Owner: PL-cef-layer. Resize sync:
PL-motion-cef. Related: [perf-lead.md](perf-lead.md) issues 2, 4, 7, 13;
[browser.md](browser.md) sections 2-3 and "Fork clip patches";
[cef-out-of-process.md](cef-out-of-process.md) option B.

## 1. Cost today (child-window path)

A Chromium page is a borderless child `NSWindow` (fork `CmuxParentViewTracker`,
`libcef/browser/chrome/views/chrome_child_window_mac.mm`) over `CEFHostView`.

- Every geometry change of any host ancestor runs `-update`. It calls `-setFrame:display:` on the
  page window, which is a WindowServer round trip. It can also call `addChildWindow`/`removeChildWindow`.
  It rebuilds a `CAShapeLayer` mask on Chromium's content view (the mask memo from 066b083f lowered this
  work) and sets `ignoresMouseEvents`. Each frame of a motion repeats this per page window.
- The page window is its own WindowServer surface. Its frame and mask commit outside the cmux
  window's CA transaction. The page tears against the pane chrome during motion, and app overlays
  must move into a child panel above every page (`WindowOverlayLayer`).
- Hide (workspace or tab switch, parent hidden): `removeChildWindow`, then `Widget::Hide`, then
  `orderOut`. Then `NativeWidgetMacNSWindowHost::OnVisibilityChanged(false)` calls
  `RecyclableCompositorMac::Suspend`, and `RenderWidgetHostViewMac::WasOccluded` makes the renderer
  hidden (`DelegatedFrameHost::WasHidden`, frames can be evicted).
- Show: `addChildWindow`, then `ShowInactive` (order in), then compositor `Unsuspend`. The window shows
  only what Chromium draws next. An evicted frame waits for the renderer.
- Resize: `NativeWidgetNSWindowBridge::UpdateWindowGeometry` calls
  `CATransactionCoordinator::Synchronize` when the content size changed. Its pre-commit handler then waits, inside
  the next Core Animation commit of the cmux main thread, while any page window's `ShouldWaitInPreCommit` is true
  (its content size is not yet its compositor frame's size), pumping Chromium's UI tasks, until the latest
  `start + PreCommitTimeout()` (`kUIPaintTimeout`, 500 ms). Read in the Chromium 154.0.8037.58 sources
  (`components/remote_cocoa/app_shim/native_widget_ns_window_bridge.mm`,
  `ui/accelerated_widget_mac/ca_transaction_observer.mm`, `ui/base/ui_base_features.cc`):
  `kOnlyUseWindowResizeHelperOnResize`, the only switch that shortens the wait to 1 ns outside a live resize, is
  disabled by default and cmux does not enable it (`CEFSwitches`). So before fork API 27 every page-window resize
  (each tracker `setFrame` during a split, close or column spring, and the window's live resize) could hold a cmux
  frame for up to 500 ms. `IsWindowInLiveResize` has one reader, that handler, and only for the disabled switch: the
  API 27 patch's `inLiveResize || timeout > 0` changes nothing in Chromium 154. The deadline is checked only between
  whole UI tasks (`WaitForSingleTaskToRun`), so one long task can pass it.
  Second wait (review 2): `Synchronize` also calls `OnActivateForTransaction`, so the GPU process starts a CA
  transaction and holds its commits for every page, and `PostCommitHandler`
  (`ui/accelerated_widget_mac/ca_transaction_observer.mm`, `content/browser/gpu/ca_transaction_gpu_coordinator.cc`)
  then waits on the cmux main thread up to `kPostCommitTimeout` (50 ms) for the GPU's `CommitCATransaction` reply.
  The API 27 patch changes only `PreCommitTimeout` and `IsWindowInLiveResize`, so this post-commit wait still runs on
  every page-window resize with a deadline of 0, hosted or not: "0 never holds the commit" is false until the fork
  skips `Synchronize()` in `UpdateWindowGeometry` for a 0 deadline (sent to PL-cef-layer for cmux.33). Not measured
  yet: either wait (`cef-resize-sync-bench.py`, `debug.motion` work `ca.commit`, which sees only the run-loop
  commit: not an explicit `CATransaction.flush()` nor AppKit's flushes inside a window live resize).

## 2. Design

Chromium already shows its GPU output through `CALayerHost` (`ui::DisplayCALayerTree`:
`GotCALayerFrame` makes a `CALayerHost` on the GPU process's `CAContext` id). The bridge creates that tree
on the layer of `ViewsCompositorSuperview` inside the page window
(`NativeWidgetNSWindowBridge::CreateContentView`).

Fork API 26, `uint32_t cmux_browser_set_layer_hosting(int browser_id, int enabled)` (branch
`cmux/8037-cmux33-layer-host`, on top of `cmux32-pump-geometry`, libcef only, no Chromium patch):

1. The tracker creates one `CAContext` per page window, on `CGSMainConnectionID()`, with an
   unflipped root layer.
2. It moves the DisplayCALayerTree's layers (its flipped layer, which holds the GPU `CALayerHost`) from the
   compositor view's layer into that root. DisplayCALayerTree keeps its own pointers, so new
   frames and GPU context changes land in the hosted tree. A content view that Chromium makes again
   gets adopted at the next update.
3. It returns the context id. The app's `CEFHostedPageView` (a layer-hosting subview at the bottom of
   `CEFHostView`, `masksToBounds`, `hitTest` nil) hosts it with its own `CALayerHost`.
   `CEFLayerHosting` (one per `CEFHostView`) owns the app side:
   - A new page window (`CEFPaneHost.windowCreated`, `CEFDevToolsController.opened`) asks at the end of the
     run-loop turn, not inside `OnAfterCreated`: Chromium adds the WebContents to its window later in that
     stack, and the fork returns 0 while the browser has no page window.
   - A refusal arms one retry at the tracker's next read of the host view (`-cmuxClipPath`, proof that the
     tracker is attached), again at the end of that turn. A second refusal waits for the next show.
     `debug.cef` `tracker.hosting_refused` counts refusals.
   - The context belongs to the page window, so a tab switch inside a hosted pane makes no fork call; a
     tunable change applies at the next show. A new page window drops the old window's context.
   - When no `CALayerHost` can show the context, hosting is turned off at once and the page keeps its window
     (never a blank page over a see-through window).
   - Teardown (DevTools closed, the pane's last tab closed) turns hosting off and removes the hosted view.
     `tracker.hosted_pages` counts the hosted views in a window, live.
4. The page window stays as a transparent input target over the host view. Its
   `ignoresMouseEvents` is set explicitly: a non-opaque window with no pixels takes the mouse only
   because of that. The tracker skips its mask while the page is hosted, but still computes
   the visible and occluded rects for mouse routing.

Cross-process ready (lead constraint): the app gets a context id, which is a WindowServer name. It does
not get a pointer. When the browser moves to a helper app, the same call returns an id from that process
and the app side does not change. The next steps, moving the input window off screen and forwarding
events, and the Chromium UI thread off the cmux main thread, keep this seam.

What this fixes:
- Pixels move, clip and show in the cmux window's own CA transaction. No tearing, and overlays are
  above the page in the same tree.
- Hide: the host layer leaves in the switch's own transaction; the page window's
  `removeChildWindow` and `Widget::Hide` run from that transaction's completion block (b2f6842a), so they
  leave the switch's turn but still run on main right after the commit. A show still orders the page window
  in (`addChildWindow`, `ShowInactive`, `setFrame`) in the switch's turn: slice 3.
- Show: not verified. A hidden page window still runs `Widget::Hide` (the compositor is suspended) and the renderer
  can evict a hidden tab's frame (section 1), so the hosted context may show nothing until Chromium's next frame.
  Slice 3 keeps the frame while hidden; until a check sees the page's pixels in the first commit after a show, do not
  count a faster show.

### Live resize (Lawrence 2026-10-23: no snapshot freeze; owner PL-motion-cef)

Every motion frame must show the page at that frame's size, in the same CA transaction as the pane.
Layer hosting makes this possible: the hosted root, the cmux layers and the GPU fence port all commit in
one main-thread transaction of one process. Fork API 27 (`cmux_browser_set_resize_sync`, designed by
PL-motion-cef) replaces `kUIPaintTimeout` for an embedded page window with the embedder's deadline, 0 by
default, so no page ever holds a cmux frame unless asked. The app asks for `browserResize.syncDeadline`
(8 ms) while a page is hosted and `browserResize.liveResizeDeadline` (16 ms) for every page during the
window's live resize (which Chromium used to keep in sync). Open (review 1): a fixed 8 ms per frame can take a
whole 120 Hz frame of the main thread while a spring runs; the frame at the new size needs a BeginFrame, so it
may often miss the deadline. Next: wait only on discrete resizes and the landing frame, or derive the deadline
from the display link's target time; no bench yet measures the main-thread wait with hosting on.

API 27 (`cmux_browser_set_resize_sync`, fork 437ed1cc): an embedded page window's `PreCommitTimeout` is the
embedder's deadline, 0 by default. While a page is hosted, `CEFLayerHosting` gives it `CEFResizeSyncDeadline`: the
`browserResize.syncDeadline` tunable (8 ms) capped at half the shortest frame of all displays (8 ms with only 60 Hz
displays, 4 ms once one runs at 120 Hz), because the wait runs on the main thread in every commit of a spring, once
for all waiting pages (the latest deadline, not a sum), and that one commit carries every cmux window. A tunable
edit or a display change (`didChangeScreenParametersNotification`) reaches the fork at the next show or display
change, with a call only when the value changed, recorded only when the fork took it, and sent to a live browser of
the page window (a closed tab hands it to another). Open: whether Chromium's frame at the new size (a renderer frame,
then a Views compositor frame driven by BeginFrame) makes that deadline at all during a spring; if it mostly
misses, the wait buys nothing and the deadline should apply only to discrete resizes and a spring's landing frame.
`cef-resize-sync-bench.py` measures it (commit time and missed frames, hosting off / on / on with 0, light and
STRESS, one run per build for API 26 against API 27). With API 27 a page that is not hosted gets 0 outside the
window's live resize; during it `CEFLayerHosting.windowLiveResize` gives every page `browserResize.liveResizeDeadline`
(16 ms), capped at half a display frame like every deadline, and 0 (or its pane deadline) after it. AppKit tells only
the views in the window when its live resize starts and ends, so a host view that changes windows
(`CEFLayerHosting.windowDidChange`) takes the new window's `inLiveResize` (review 3: a view parked during a live
resize kept the live-resize wait for every later pane resize).

Divider drags (cmux#26037): Debug Settings `browserResize.dragResize` has a fourth mode, `resizeSync`. The page lays
out live, and from the drag's first move until its release landed (`PaneResizeGestureFollowing`, the same start and
end `hold` uses) `CEFLayerHosting.paneResizeDrag` gives every page window over the dragged pane (the page's and a
docked DevTools'), hosted or not, `browserResize.dragResizeDeadline` (16 ms) under the half-frame cap. The cap is the
answer to review 1's open point for drags: half the shortest display frame keeps each commit inside its display
link's target time, so a frame the page misses shows its last frame instead of dropping the app's. Only the drag and
its landing wait; a spring the drag did not start keeps the pane deadline. Below API 27 the mode is `live`. Still
open: the split_resize numbers for `resizeSync` against `live`, `hold` and `synced` on one host, which need the
API 27 pin and the harness's variants, before it can be the default.

## 3. Features, status

| Feature | Expected with hosting | Status |
|---|---|---|
| Mouse, scroll, hover | page window (input target) as today | open (verify the explicit `ignoresMouseEvents` on a no-pixel window) |
| Keyboard, IME, focus | page window is key, as today | open |
| Context menus, select popups, bubbles | own windows, as today | open |
| Accessibility | page window AX tree; `CmuxApplication` maps windows | open |
| DevTools docked or in its own cmux window | its own page window over its own `CEFHostView` (`CEFDevToolsController.views.host`), so its own context: hosted from `opened` (end of that turn); a tunable change applies at the next open; close turns it off (`removeViews`) | code in, not run (fork API 26 build pending) |
| Drag and drop | page window is the drag destination and source | open |
| Full screen | host layer moves with the cmux window; tracker follows | open |
| Popup windows | a popup host (`adoptPopup` placeholder window) asks like any pane host (`CEFPaneHost.windowCreated` makes no exception for `isPopupHost`); extension popup windows that attach later (API 13 trackers) are not hosted | open (not verified on screen) |

## 4. Risks

- `CALayerHost` and `CAContext` are QuartzCore SPI. Chromium (every Chrome and Electron app) and
  WebKit's UI process use the same classes. cmux is not in the App Store. Notarization does not check SPI.
- The flip of the hosted root inside the layer-hosting view must be checked on screen.
- The page window still costs a WindowServer surface and the per-frame `setFrame` while panes move (input only,
  invisible). Slice 3 removes the orders that are not needed. The final step forwards input and keeps the window off screen.

## 5. Slices

1. Fork API 26 plus the app behind `BrowserResizeTunables.layerHosting` (default off). Fleet build of the fork
   (`cmux-ci build cef`, job 5c9597f4ab841a1cd6f07340, about 1.6 h cold, 5-10 min incremental).
   Pin as a dev artifact and verify every row of section 3.
2. Bench the child-window path against hosting, light and STRESS, on a fleet GUI host: workspace switch, tab switch,
   split, close, scroll, full screen. Target < 10 ms p95 to commit, 0 dropped frames.
3. Switch path: keep the frame while hidden (no eviction of a recently shown tab), and no `orderOut` or
   `removeChildWindow` churn for an input-only window. Overlays stay in the root while every page is hosted.
   Today (fork b2f6842a) only the hide waits for the commit, and it still runs right after it on the main thread
   (`removeChildWindow`, `Widget::Hide`), so its cost moves to the next frame or input; a show still runs
   `removeChildWindow`/`addChildWindow`, `ShowInactive` and `setFrame display:YES` in the switch's turn (12 windows
   for a STRESS workspace). Measure input to commit for both directions with the `action.perform`/`action.commit`
   signposts, light and STRESS, then remove the show side (the input window stays ordered in, or moves off screen).
4. Default on, after parity.

## 6. Measured: hosting off vs on, fork API 30 (2026-11-01)

Build: feat-cmux-next a3c23b79cc5b (with resize sync, #26595) and the engine pinned to cef-154.0.28-cmux.36 (fork API 30,
`cmux/8037-helper-items`), measurement only: cmux.36 lacks the cmux.38 CVE backport, so it is not a shipping pin. Fleet
minis in a console session at 60 Hz, a DEV build of the commit (Debug). Steps (fleet `cmux-ci run` ids): A/B
0e2cfd8e23254fe2a40fdf6b and 93a389c596317f756c8582fa (STRESS on a 1920x1200 virtual display), divider drags
6497317fab135acce2c326a3, ec26f2b5d8d1c37b906b057c and 2720dca1c3486b2a91bf93d5. One run per mode unless n says
otherwise: read these as a direction, not a budget.

| metric | off (child window) | on (hosted) | delta | harness |
|---|---|---|---|---|
| mode is real (verify `valid`, `hosted`, `hosted.fork`) | pass, page window holds the CALayerHost | pass: fork_api 30, hosted_pages >= 1, CALayerHost in the hosted context, 0 in the page window | | `cef-layer-verify.py --checks hosted` |
| tab switch, Chromium, 2 tabs click: e2e / commit median | 32.3 / 19.2 ms | 20.0 / 12.0 ms | -12 / -7 ms | `tab-switch-matrix.py --kinds chromium` |
| tab switch, Chromium, 10 tabs Ctrl-Tab: e2e / commit median | 21.0 / 20.0 ms | 18.6 / 17.1 ms | -2 / -3 ms | same |
| tab switch, Chromium, 10 tabs click: commit median (two hosts) | 17.4, 19.9 ms | 12.7, 15.4 ms | -5 ms | same |
| workspace switch to a Chromium workspace, click: input to commit p50 / p95 | 27.7 / 54.0 ms | 27.8 / 46.1 ms | even | `sidebar-stress-bench.py switch_matrix` |
| light (1x2, 4x2, page top left) split / close / drag: missed frames, 3 rounds | 6 / 2 / 0 (1x2), 4 / 2 / 5 (4x2) | 5 / 3 / 0, 5 / 4 / 7 | +0-2 | `pane-perf-terminal.py --browser` |
| light 4x2 drag, missed frames, 3 rounds, second host | 27 | 71 | +44 (not seen on the first host, nor in the resize bench: 19 off, 14 on) | same |
| STRESS split / close / column / column-close / drag: missed frames | 9 / 9 / 19 / 12 / 77 | 10 / 9 / 23 / 13 / 78 | +0-4 | `cef-resize-sync-bench.py` |
| STRESS column-close: longest frame | 83 ms | 256 ms (syncDeadline 0: 243 ms) | +173 ms, one run | same |
| STRESS with syncDeadline 0 (`on0`) missed frames, same actions | | 9 / 7 / 18 / 13 / 77 | equals off | same |
| divider drag beside a page, layout lag p95: median / max of 9 runs | live 0.65 / 26.2 ms | live hosted 9.6 / 9.7 ms | | `split-resize-bench.py` |
| same, resize sync (`dragResize` resizeSync) | 0.84 / 9.6 ms | 1.98 / 9.7 ms | max -16.5 ms vs live | same |
| same, app frames dropped per drag (mean of 9) | live 1.67, resizeSync 1.67 | live 1.0, resizeSync 1.56 | even | same |

What this says:
- Hosting costs no frames in light layouts and at most a few in STRESS, and makes Chromium tab switches 3-7 ms faster
  to commit (up to 12 ms end to end). The one large miss (a 256 ms column-close frame in STRESS) is one run, and it shows with syncDeadline 0
  too, so it is not the resize wait.
- Resize sync caps how far a page lags a dragged divider: the worst p95 of 9 runs is 9.6 ms against 26 ms for live,
  with no more dropped app frames. `hold` lags 194-226 ms; `synced` is close to resize sync, but it is a launch switch
  that waits up to 500 ms.
- Not proven: the verify rows that read pixels or deliver input (`pixels.*`, `show.again`, `click`, `keys`, `scroll`,
  `drag`, `context`, `resize.top`) fail the same way in mode off on the fleet minis. Window images there hold no
  Chromium pixels, `screencapture` writes nothing (no Screen Recording grant), and no posted event reaches the page.
  They need a host with those grants before hosting can default on (section 3's open rows stay open).

Harness fixes made for these runs (same PR): `cef-layer-verify.py --tunables build` read the file path from
`debug.tunables set`, whose reply is the tunable's row (it now reads `state`), so every A/B run refused to bench.
It now starts from an empty saved session and writes the mode before launch. show.again goes back to the probe's
own workspace by id; `workspace.selectFirst` showed the launch's workspace, so every later row read no page. The A/B
validity gate is the three mode rows, and show.again is recorded. `bench_launch.py` keeps the build's Debug Settings
file when it moves the saved session aside, so the mode the A/B set still applies.

Remaining before default on:
1. A shipping pin at fork API >= 27 with the CVE fix: cmux.39 (the API 30 line rebased on the cmux.38 security
   line). Until then the tunable and resize sync are inert for users (cmux.38 is API 24).
2. Pixel and input rows on a host with Screen Recording and event posting, both modes.
3. STRESS column-close, more runs; if the long frame holds, trace it (page-window show and order churn, slice 3).
4. The post-commit GPU wait (section 1): the fork still calls `Synchronize()` at a 0 deadline.
5. Popups and DevTools in hosted mode on screen (section 3).
