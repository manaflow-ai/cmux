# cmux phone control

`CmuxPhoneControl` is the open-source control plane for agents that need to
observe and operate a phone from cmux. It is intentionally a small,
versioned protocol with explicit capability reporting. A client can discover a
device, open a session, take a screenshot, inspect an accessibility tree, and
send idempotent actions while checking the screen sequence that it observed.

The first vertical slice lives in
`Packages/Shared/CmuxPhoneControl`. It contains the protocol library, a
deterministic mock source, a WebDriverAgent adapter, and the `cmux-phone`
newline-JSON command. Run its local proof with:

```sh
cd Packages/Shared/CmuxPhoneControl
swift run cmux-phone self-test
```

An agent can use the same control channel without a GUI:

```sh
printf '%s\n' \
  '{"protocol":"cmux.phone","version":1,"type":"request","id":"1","method":"device.list"}' \
  '{"protocol":"cmux.phone","version":1,"type":"request","id":"2","method":"session.open"}' \
  | swift run cmux-phone mock-server
```

The protocol is newline-delimited JSON (`cmux.phone` version 1). Requests have
an id, method, optional session id, and JSON parameters. Responses echo the id;
events carry a session id and monotonic sequence. Control lines are capped at
64 KiB. Screens are represented as base64 PNG/JPEG in the response model for
the local MVP; a native streaming transport can add binary frame delivery
without changing action semantics.

## Sources and capabilities

The mock driver is used by tests and examples. `WebDriverAgentDriver` talks to
a signed XCTest/WebDriverAgent runner through a loopback HTTP forward (usually
`127.0.0.1:8100`). It maps WDA screenshots and JSON accessibility source into
the common models, then translates normalized coordinates to device points.
WDA is a developer adapter: the device must be paired and trusted, Developer
Mode must be enabled, a runner must be signed for the current team, and the
Developer Disk Image must be mounted. Keep its HTTP and MJPEG ports on
loopback; do not expose them on a LAN.

Apple's public iOS capture APIs (ReplayKit and the newer ScreenCaptureKit
picker) require an explicit user choice and capture consent. They do not inject
touches into arbitrary third-party apps. A future companion source can use
those APIs for consented capture of its own UI, while cross-app developer
automation remains an XCTest/WDA capability.

macOS iPhone Mirroring is a separate host source. ScreenCaptureKit can capture
the mirroring window after Screen Recording permission, and macOS Accessibility
or target-process events can drive the host window after Accessibility
permission. This source reports `screen_snapshot` and coordinate capabilities
only unless a semantic tree is available; it never pretends that the host AX
tree is the remote phone's tree.

## Safety and reliability

Every input action has an `action_id`. Drivers return the original receipt for
duplicates, so a retried request cannot tap twice. Clients may include the
`screen_seq` from the frame they used; stale coordinates are rejected and the
client can refresh before retrying. The session emits `ui.changed` after an
accepted action and includes the resulting sequence in the receipt.

Logs should contain request ids and capability errors, never screenshot bytes,
password fields, or typed secrets. The production daemon should add authenticated
local IPC, per-device leases, cancellation, and bounded frame queues before it
binds beyond loopback.

## Research references

- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [ReplayKit / RPScreenRecorder](https://developer.apple.com/documentation/replaykit/rpscreenrecorder)
- [AXUIElement](https://developer.apple.com/documentation/applicationservices/axuielement)
- [XCTest UI automation](https://developer.apple.com/documentation/xcuiautomation)
- [WebDriverAgent](https://github.com/appium/WebDriverAgent)

These references describe the platform permissions and runner requirements;
they are not bundled into the protocol package.
