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
