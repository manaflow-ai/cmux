# Phone control research and architecture

This note records the platform research behind `CmuxPhoneControl`. The goal is
to make the boundary between observation, semantic discovery, and input
explicit so a client can choose a source from its reported capabilities.

## What the public APIs provide

**Host-side mirroring.** ScreenCaptureKit can enumerate shareable windows with
`SCShareableContent`, select one with `SCContentFilter`, and capture a still
image with `SCScreenshotManager`. The capture is consent-gated by macOS Screen
Recording permission and is a host-window image; it is not a remote iOS
accessibility tree. The mirroring driver therefore crops the selected window's
content area, reports `screen_snapshot`, and leaves semantic discovery
unavailable.

**Host-side input.** macOS Accessibility permission is exposed through
`AXIsProcessTrusted`. Once the user grants it, Quartz `CGEvent` instances can
be posted to the mirroring process with `postToPid`. Posting to a target PID
keeps the host's frontmost application unchanged, but the coordinate mapping
still belongs to the mirrored window and must account for title-bar/content
insets. The driver converts normalized points into that content rectangle and
does not claim that a host AX node represents a phone control.

**Real-device semantic control.** XCTest's `XCUIApplication` and the
WebDriverAgent HTTP contract provide the semantic and input operations needed
for a paired developer device: readiness, a session, window geometry, PNG
screenshots, JSON accessibility source, taps, drags, text, and physical-button
commands. The cmux adapter talks to a signed runner through an HTTP forward on
loopback, validates the session response, refreshes geometry before every
operation, and bounds streamed response bodies before JSON decoding.

**Public iOS capture limits.** ReplayKit and the iOS capture APIs require an
explicit user choice and capture consent. They are suitable for a companion
app's own UI, but they do not grant arbitrary cross-app touch injection or a
remote semantic tree. That is why the real-device path is a signed XCTest
runner and the host path is consented window mirroring.

## Source selection

| Source | Observation | Semantic tree | Input | Required user state |
| --- | --- | --- | --- | --- |
| Mock | deterministic PNG-like bytes | deterministic tree | all protocol actions | none |
| WebDriverAgent | PNG screenshot | JSON source mapped to normalized bounds | tap, swipe, long press, text, button | paired/trusted phone, Developer Mode, signed runner, loopback forward |
| iPhone Mirroring | cropped ScreenCaptureKit image | unavailable by design | tap and swipe | phone unlocked and mirrored; Screen Recording and Accessibility permissions |

The protocol keeps these differences in `PhoneCapabilities`. An agent should
discover the device first, open one session, take a snapshot, optionally read
the tree, and include the observed `screen_seq` with coordinate actions. An
accepted action returns an idempotent receipt and a `ui.changed` event.

## End-to-end boundary

The typed `PhoneControlClient` is the agent-facing side of the same bounded
newline protocol served by `PhoneTCPServer`. It is loopback-only, serializes
requests, retains events while waiting for a response, and exposes typed
helpers for discovery, sessions, frames, trees, and actions. The package's
`tcp-self-test` runs that client against a real TCP listener and the mock source;
the same client can select the WDA or mirroring source through
`cmux-phone tcp-server`.

The wire server deliberately has no network authentication. It binds to
`127.0.0.1` and is intended to sit behind an authenticated local launcher or
forwarder when an agent runs outside the host process. The request and response
limits, per-connection lease, stale-screen check, bounded action replay, and
connection cleanup are protocol safety properties rather than a substitute for
that outer identity boundary.

## References

- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)
- [AXUIElement](https://developer.apple.com/documentation/applicationservices/axuielement)
- [Accessibility APIs](https://developer.apple.com/documentation/applicationservices/axuielement)
- [XCUIApplication](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication)
- [ReplayKit](https://developer.apple.com/documentation/replaykit)
- [WebDriverAgent](https://github.com/appium/WebDriverAgent)
