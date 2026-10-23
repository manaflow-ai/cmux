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
  `CATransactionCoordinator::Synchronize`. Its pre-commit wait is skipped outside a real live resize
  (`kOnlyUseWindowResizeHelperOnResize`: the wait is 1 ns when no observed window `inLiveResize`).
  So a pane resize shows the old-size frame (a gap or a clip) until Chromium catches up.

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
     tracker is attached), again at the end of that turn. A refusal of the retry is the page window's answer:
     no tab show asks again (a show is the 10 ms tab-switch path); a new page window or a move of the host view
     (`pageMoved`: a docked DevTools changing side or window) does, once.
   - Every request addresses the window's live browser (`anchor`), never the browser that created the window: a
     spare window's or popup host's about:blank placeholder is closed by the time a retry runs. DevTools passes
     its browser. Open (PL-cef-tab owns `CEFPaneHost`, asked 2026-10-23): `windowCreated` passes
     `anchorBrowser`, and `movePopupsIn` calls `pageShown` for the popup that moved in; until then a pane's
     request addresses the browser shown last, and a popup host waits for its next show.
   - The context belongs to the page window, so a tab switch inside a hosted pane makes no fork call; a
     tunable change applies at the next show. A new page window drops the old window's context.
   - When this process has no `CALayerHost` (`CEFHostedPageView.canShowContexts`, asked once per process) the
     fork seam is nil and nothing calls the fork. When a context cannot be shown anyway, hosting is turned off
     at once, the page keeps its window (never a blank page over a see-through window), and that page window
     makes no more calls.
   - Teardown (DevTools closed, the pane's last tab closed) removes the hosted view with no fork call: the
     window's browsers are gone, and the window's teardown releases its tracker's context.
   - `debug.cef` `layer_hosting` is a gauge of the live host views (`host_views`, `hosted_pages` in a window,
     `refusals`, `fork_calls`), worked out from the runtime's hosts and tabs when read; `tracker` stays counters
     since launch.
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
- Show: the context keeps the last committed frame while the page is hidden, so the host shows
  it at once.

### Live resize (Lawrence 2026-10-23: no snapshot freeze; owner PL-motion-cef)

Every motion frame must show the page at that frame's size, in the same CA transaction as the pane.
Layer hosting makes this possible: the hosted root, the cmux layers and the GPU fence port all commit in
one main-thread transaction of one process. The remaining piece is a fork switch that makes the
bridge's pre-commit wait apply during embedder motion, so the page window counts as in live resize,
with an embedder deadline instead of `kUIPaintTimeout` (500 ms). PL-motion-cef builds it as API 27 on top of
this branch.

## 3. Features, status

| Feature | Expected with hosting | Status |
|---|---|---|
| Mouse, scroll, hover | page window (input target) as today | open (verify the explicit `ignoresMouseEvents` on a no-pixel window) |
| Keyboard, IME, focus | page window is key, as today | open |
| Context menus, select popups, bubbles | own windows, as today | open |
| Accessibility | page window AX tree; `CmuxApplication` maps windows | open |
| DevTools docked or in its own cmux window | its own page window over its own `CEFHostView` (`CEFDevToolsController.views.host`), so its own context: hosted from `opened` (end of that turn); DevTools has no tab shows, so each placement change (dock side, into or out of its own window) asks again after a refusal and applies a tunable change; close removes the hosted view (`removeViews`) | code in, not run (fork API 26 build pending) |
| Drag and drop | page window is the drag destination and source | open |
| Full screen | host layer moves with the cmux window; tracker follows | open |
| Popup windows (API 13 trackers) | not hosted in slice 1 | open |

## 4. Risks

- `CALayerHost` and `CAContext` are QuartzCore SPI. Chromium (every Chrome and Electron app) and
  WebKit's UI process use the same classes. cmux is not in the App Store. Notarization does not check SPI.
- The flip of the hosted root inside the layer-hosting view must be checked on screen.
- Slice 1 adds work and removes none: with hosting on, every motion frame still runs `-update` with its
  `setFrame:display:` (a WindowServer round trip), the page window still orders in and out on hide and show, and
  the tracker still reads the clip and occlusion rects; the `CALayerHost` compositing and an invisible,
  transparent window surface come on top. An off/on A/B (`cef-layer-ab.py`) shows tearing parity and the cost that
  remains (its `cost` rows: `geometry_posts`, `clip_reads`, `fork_calls` per mode), not a speed gain. Slice 3
  removes the orders that are not needed. The final step forwards input and keeps the window off screen.

## 5. Slices

1. Fork API 26 plus the app behind `BrowserResizeTunables.layerHosting` (default off). Fleet build of the fork
   (`cmux-ci build cef`, job 5c9597f4ab841a1cd6f07340, about 1.6 h cold, 5-10 min incremental).
   Pin as a dev artifact and verify every row of section 3.
2. Bench the child-window path against hosting, light and STRESS, on a fleet GUI host: workspace switch, tab switch,
   split, close, scroll, full screen. Target < 10 ms p95 to commit, 0 dropped frames.
3. Switch path: keep the frame while hidden (no eviction of a recently shown tab), and no `orderOut` or
   `removeChildWindow` churn for an input-only window. Overlays stay in the root while every page is hosted.
4. Default on, after parity.
