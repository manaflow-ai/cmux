# iOS browser streaming

cmux iOS gets a remote browser surface: a live, pixel-accurate mirror of a
browser pane running in cmux on the Mac, with full interaction (tap, scroll,
type, navigate) forwarded to the real `WKWebView` on the Mac. The phone shows
exactly what the Mac tab shows, because the frames are rendered by the Mac tab.

This is distinct from `CmuxMobileBrowser`, the phone-local WKWebView pane.
That pane browses on the phone with phone cookies; this surface mirrors the
Mac's session, page state, and pixels.

## Why streaming, not URL sync

Re-opening the Mac tab's URL in a phone WKWebView loses everything that makes
the Mac tab that tab: logged-in sessions, SPA state, form contents, scroll
position, dev servers bound to the Mac's localhost. Streaming the Mac-rendered
pixels is the only design where "what you see on the phone" is by construction
identical to "what the Mac tab shows", including `localhost:3000`.

## Capture (Mac)

Frames come from `WKWebView.takeSnapshot(with:)` on the pane's live web view,
the same API the browser screenshot pipeline already uses. For the stream
lifetime, cmux moves the web view's presentation root into the screenshot
pipeline's borderless offscreen render window and sizes that window to the
phone's point viewport. WebKit therefore reflows and snapshots in a real
rendering host at phone width, including when the page was already loaded and
idle. Rotation resizes the same host; it does not reparent the view per frame.

The snapshot renders in the web content process, so it never picks up cmux
chrome or overlays. No Screen Recording permission is required. ScreenCaptureKit
was rejected for exactly those reasons: TCC prompt, captures overlays, and
cannot capture a pane whose portal is detached. While streaming, the live web
view renders in the offscreen host at phone width, so the Mac pane cannot show
it at Mac width at the same time. Instead the pane shows a read-only mirror of
the same frames the phone receives, letterboxed and click-through, so the Mac
reflects the phone session rather than going blank. Teardown removes the mirror
and restores the presentation root to its captured on-screen superview, sibling
position, and geometry, returning the pane to a full-width live web view.

Capture is dirty-driven, not clocked. While a stream is active, the panel
injects a user script that reports paint activity (a throttled
`requestAnimationFrame` beacon plus scroll/resize/input listeners) through the
existing script message channel. Native signals (navigation callbacks, title
changes) also mark the stream dirty. The capture loop snapshots only when
dirty, coalesced to a frame budget (default 30fps cap), so an idle page costs
zero CPU and a playing video streams continuously.

Snapshots are taken at the web view's backing scale (2x) so text stays crisp
on the phone.

## Encoding

Each frame is encoded independently and tagged with a format, so the encoder
can evolve without protocol changes:

- `jpeg` while the page is active (quality adapts to measured throughput),
- `png` as a lossless settle frame ~300ms after the last dirty signal, so a
  page at rest is pixel-perfect with zero compression artifacts.

Flow control mirrors the terminal stream-token pattern: every frame carries a
monotonically increasing sequence, the phone acks what it displayed, and the
Mac coalesces (drops intermediate frames, never queues) when more than a small
window is unacked. Slow links degrade to lower fps and quality, never to lag.
H.264/HEVC via VideoToolbox is a planned upgrade behind the same format tag.

## Input (Mac)

Phone gestures are replayed as real AppKit events delivered to the pane's
`CmuxWebView`, not as synthesized DOM events, so pages see trusted events and
native scrolling:

- tap → `NSEvent` mouseDown/mouseUp pair at the page point (view-local
  coordinates converted through the web view), with click count for
  double-taps,
- scroll → `scrollWheel` events with proper gesture phases; the phone streams
  per-frame deltas from a native `UIScrollView` tracking gesture, so momentum
  and deceleration feel native on both ends,
- keys → `keyDown`/`keyUp` NSEvents for ASCII and special keys (return, tab,
  arrows, delete, escape); non-ASCII text falls back to focused-element text
  insertion. IME composition is a known v1 limitation.

Events are delivered straight to the view, not through `NSApp.sendEvent`, so
streaming input never steals macOS focus or raises the window.

## Wire contract

New `mobile.browser.*` methods on the existing mobile host, alongside
`mobile.terminal.*`:

- `mobile.browser.list` — browser panels in a workspace: `panel_id`, `url`,
  `title`, page point size.
- `mobile.browser.stream.start` / `stop` — subscribe to frames for a panel.
  Start returns the current frame immediately.
- `mobile.browser.frame` (push) — sequence, format, page-point size, pixel
  size, payload.
- `mobile.browser.frame.ack` — flow control.
- `mobile.browser.input.pointer` / `.scroll` / `.key` / `.text` — input
  replay.
- `mobile.browser.navigate` / `.back` / `.forward` / `.reload` — chrome
  actions, answered with `url`/`title`/`can_go_back`/`can_go_forward` push
  updates (`mobile.browser.state`).

Capability `browser.stream.v1` is advertised so old phones and old Macs
degrade cleanly.

## iOS surface

A new `CmuxMobileBrowserStream` package following the terminal surface
pattern: an `@Observable` per-panel state object beside the shell store (kept
out of `MobileShellComposite` so workspace re-syncs cannot clobber it), a
`UIViewRepresentable` whose coordinator consumes an `AsyncStream` of decoded
frames, and a delegate sink that forwards gestures to store RPCs.

The view is a `UIView` whose layer displays the latest decoded frame
(decode off-main, stale frames dropped), fitted to width. A transparent
`UIScrollView` supplies native pan mechanics whose deltas become Mac scrolls;
pinch zooms locally (a lens over the mirror, never page zoom); when zoomed,
pans move the local viewport and a double-tap resets. Tap points are mapped
through the current fit/zoom transform into page points.

Chrome matches the app's glass design: title/URL pill, back/forward/reload,
loading progress from `mobile.browser.state`, and a connection state overlay
reusing the terminal's disconnect/reconnect patterns. Entry point: the
workspace toolbar picker lists the Mac workspace's browser panels next to its
terminals.

## Lifecycle

Streams are reference-counted per panel and stop on: explicit stop, phone
disconnect, panel close (pushed as `mobile.browser.closed`), or app
background. Reconnect resubscribes and the first frame repaints the surface;
sequence numbers restart per subscription. The Mac-side hidden-webview
discard manager treats an actively streamed panel as visible so the web
process stays alive while a phone is watching. The final subscriber teardown
also closes the offscreen render window and restores the saved pre-stream
viewport and presentation hierarchy. Element fullscreen and attached-inspector
layouts stay on-screen and use ordinary visible-viewport capture rather than
being moved into the offscreen host.
