# Smooth mouse-wheel scrolling in web views (2026-10-24)

User: "make webviews mouse scroll smoothly in Swift like Chrome: Chrome smooth-scrolls
with an external mouse, Safari/WebKit with an external mouse janks."

## Problem

A mouse-wheel notch reaches `WKWebView.scrollWheel(with:)` as a discrete event
(`hasPreciseScrollingDeltas == false`, no phase, no momentum). WebKit scrolls it in one jump
(3 lines = 120 px). Chrome spreads the notch over about 150 ms.

## Options weighed

1. **WebKit preference.** `WKPreferences._features` (601 features on macOS 27) has
   `ScrollAnimatorEnabled` ("Scroll animator", default off) and
   `EventHandlerDrivenSmoothKeyboardScrollingEnabled` (keyboard only). No `_smoothScrollingEnabled`
   selector exists. Measured with `ScrollAnimatorEnabled` on and a 3-line notch: still one 120 px
   jump (1 distinct position). Rejected. (Private-feature toggles would also be a risk on
   Sequoia/26 updates.)
2. **JS smooth scroller injected in pages.** Cannot see native scrollers, breaks `preventDefault`
   ordering, needs per-page script in third-party pages. Rejected.
3. **Intercept in the view and re-feed pixel events (chosen).** `SmoothWheel`
   (`CmuxNextCompat/SmoothWheel.swift`) takes a plain vertical discrete notch in `scrollWheel(with:)`,
   keeps its distance (`scrollingDeltaY` x 40 px/line, WebKit's own line step), pays it over 150 ms
   on a cubic ease-out (`SmoothWheelCurve`, Chrome's curve) driven by `NSView.displayLink`, and
   delivers each frame to `super.scrollWheel(with:)` as a synthesized continuous, phase-less
   `CGEvent` (pixel units). WebKit then handles it as a pixel scroll: wheel listeners and
   `preventDefault`, nested scrollers and chaining, scroll snap.
   - No phase, so no rubber band and no scroll latching (a mouse has neither).
   - Notches that arrive mid-animation add to what is left and restart the ease (speeds up like Chrome).
   - A window-less `NSEvent` reports its screen point as `locationInWindow`; the event is built so
     that value equals the original notch's `locationInWindow`.

## Not touched (pass straight through, queued steps flushed first)

Precise or phased/momentum events (trackpad, Magic Mouse), Shift/Control/Option/Command wheel
(horizontal, page zoom, layout gestures), a notch with a horizontal part, Reduce Motion
(`accessibilityDisplayShouldReduceMotion`), and `browser.smoothWheelScroll = false`
(Settings > Browser > Scrolling; default on; the App follows the snapshot).

## Where

`WebKitWebView` (browser tabs), `PageWKWebView` (Markdown, Monaco, Settings and every first-party
page), `AgentPaneWKWebView` (old agent host). `AgentActivityHostView` is a fallback-only plain
`WKWebView` (the app shows Activity on the page host) and the warm-up view is never visible:
both left alone.

## CEF

CEF browser panes are Chromium, which animates wheel scrolling itself; cmux passes no
`--disable-smooth-scrolling` (grep of `CmuxNextBrowser/CEF`). Not measured here (needs a
Chromium build on a display): treat as "matches Chrome by construction", unverified.

## Tests

`SmoothWheelCurveTests` (curve: several frames, distance kept, notches add up, frame-rate
independent) and `SmoothWheelPageTests` (a real `PageWKWebView`: a discrete notch yields >= 6
increasing intermediate `scrollY` values and the exact total; a continuous pixel event scrolls at
once; Shift/Cmd/Ctrl, setting off and Reduce Motion are not animated).

## Frame timing (WKWebView, macOS 27, 120 Hz display, 3-line notch, JS timer sampling every 4 ms)

| | distinct positions | span | final |
|---|---|---|---|
| before | 1 (jump at 0 ms) | 0 ms | 120 px |
| after | 9-14 (e.g. 0, 42, 56, 68, 78, 87, 95, 101, 106, 111, 114, 116, 119, 120) | 152-183 ms | 120 px |

Not measured: macOS 15 Sequoia (no machine tried), real mouse hardware, CEF.
