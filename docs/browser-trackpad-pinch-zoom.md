# Browser Trackpad Pinch Zoom

## Summary

Browser panes now handle the native AppKit magnification gesture and apply each finite gesture delta to the active `WKWebView.pageZoom`. The gesture uses the same `0.25...5.0` bounds and automation viewport limit as menu- and API-driven page zoom.

The implementation is intentionally narrow:

- `CmuxWebView.magnify(with:)` forwards `NSEvent.magnification` when a browser-panel handler is installed.
- `BrowserPanel` adds the delta to the current page zoom instead of replacing it, preserving continuous trackpad behavior.
- Missing handlers fall back to `super.magnify(with:)`.
- A weak, identity-checked callback prevents a replaced or stale web view from mutating the current browser.
- Existing zoom validation remains authoritative for non-finite input, zoom bounds, and the 4096 × 4096 automation viewport ceiling.

## Behavior contract

| Input | Result |
|---|---|
| Positive magnification delta | Increase the active page zoom additively |
| Negative magnification delta | Decrease the active page zoom additively |
| Non-finite delta | Ignore without changing page zoom |
| Delta beyond supported range | Clamp through the existing `0.25...5.0` zoom path |
| Magnification after profile/web-view replacement | Ignore the stale view callback |
| Magnification with no browser handler | Preserve the `WKWebView`/`NSResponder` fallback |

Navigation swipes, scrolling, editable focus, popups, and ordinary browser pointer handling are unchanged because the implementation overrides only AppKit's dedicated magnification responder callback.

## TDD coverage

The tests were committed before the implementation and cover:

1. Direct invocation of `CmuxWebView.magnify(with:)` using a controlled synthetic `NSEvent`, including routing only when a handler is installed.
2. Positive and negative deltas applied to the current zoom.
3. Rejection of `NaN` and infinity plus reuse of existing bounds.
4. Preservation of the 4096 × 4096 automation viewport render limit.
5. Ignoring a stale callback after browser-profile replacement.

## CI evidence

The focused `BrowserPanelTrackpadMagnificationTests` suite passed all five cases on macOS 15 in [compatibility run 30202672962](https://github.com/usr-bin-roygbiv/cmux/actions/runs/30202672962). The full run was not green: other suites later reported failures, and the macOS 15 job was cancelled at its 60-minute limit while `GlobalSearchShortcutSettingsTests` was running. The macOS 14 matrix job reported failure without recording any steps or logs.

The repository's standard [CI run 30202484638](https://github.com/usr-bin-roygbiv/cmux/actions/runs/30202484638) stopped in its workflow guard before macOS tests because the compared upstream history changed iOS SwiftPM dependencies without matching `Package.resolved` changes. That pre-existing policy failure is outside this browser-only diff.

## Tagged application smoke

A tagged macOS application was built from implementation commit `b32f332070` by [workflow run 30202484640](https://github.com/usr-bin-roygbiv/cmux/actions/runs/30202484640).

The application was launched on an Apple Silicon laptop running macOS 15.7.5 against a deterministic local HTML fixture. The smoke used the same `WKWebView.pageZoom` mutation pipeline exposed to the gesture bridge:

| Observation | Reset | Three zoom-in steps | Reset after zoom |
|---|---:|---:|---:|
| CSS viewport width | 760 px | 584 px | 760 px |
| CSS viewport height | 610 px | 469 px | 610 px |
| Browser-owned PNG size | 17,688 bytes | 19,367 bytes | — |

All smoke assertions passed:

- Zooming in reduced the CSS viewport width.
- Reset restored the original viewport width.
- The browser-owned PNG changed after zoom.

The before/after PNG SHA-256 values differed; the report omits them because the observable result is the changed rendered image rather than a machine-specific fingerprint.

## Validation boundary

The public Core Graphics event API does not expose a supported way to synthesize a physical trackpad magnification event. The automated evidence therefore divides cleanly:

- Unit coverage directly invokes `CmuxWebView.magnify(with:)` with an `NSEvent` test subclass whose magnification delta is controlled, proving that the responder override forwards the event delta into the installed callback.
- The remaining focused cases test the resulting panel zoom behavior and safety boundaries, and the tagged-app smoke proves that the page-zoom mutation changes and restores real WebKit rendering.
- A literal physical two-finger gesture was not programmatically injected, so the report does not claim HID-level event-delivery proof.

## Related issues

| Item | Current state | Relevance |
|---|---|---|
| [#346](https://github.com/manaflow-ai/cmux/issues/346) | Open | Direct request for browser pinch-to-zoom support. This change implements that browser behavior. |
| [#1934](https://github.com/manaflow-ai/cmux/issues/1934) | Open | Requests a configurable default zoom. This change does not add a persisted default. |

## API rationale

- [`NSEvent.magnification`](https://developer.apple.com/documentation/appkit/nsevent/magnification) is the amount to add to the current magnification.
- [`NSResponder.magnify(with:)`](https://developer.apple.com/documentation/appkit/nsresponder/magnify(with:)) receives magnification gestures for the view under the touches.
- [`WKWebView.pageZoom`](https://developer.apple.com/documentation/webkit/wkwebview/pagezoom) is the existing page-zoom property used by browser controls and automation.

Using the native responder callback avoids scroll-wheel heuristics and keeps one zoom implementation for trackpad, menu, and automation paths.
