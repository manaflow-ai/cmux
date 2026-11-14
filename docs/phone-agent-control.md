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

For a persistent local socket, run `swift run cmux-phone tcp-server --port 0`.
The command prints the selected port and binds only to `127.0.0.1`; clients
still use the same newline envelopes and session lifecycle. Select a source with
`--source mock`, `--source wda --url http://127.0.0.1:8100`, or
`--source mirroring` on macOS.

Agents that run on the same Mac can use the typed `PhoneControlClient` or run
`swift run cmux-phone tcp-self-test` to exercise discovery, session opening,
snapshot, input, events, and close through the real loopback transport. The
platform research and source-selection matrix live in
[`docs/phone-agent-control-research.md`](phone-agent-control-research.md).

The protocol is newline-delimited JSON (`cmux.phone` version 1). Requests have
an id, method, optional session id, and JSON parameters. Responses echo the id;
events carry a session id and monotonic sequence. Incoming control requests are
capped at 64 KiB; response and event lines are capped at 8 MiB so a normal
base64 PNG can travel through the local MVP. A native binary frame transport
can lower the response-line limit later without changing action semantics.

## Sources and capabilities

The mock driver is used by tests and examples. `WebDriverAgentDriver` talks to
a signed XCTest/WebDriverAgent runner through a loopback HTTP forward (usually
`127.0.0.1:8100`). It maps WDA screenshots and JSON accessibility source into
the common models, then translates normalized coordinates to device points.
WDA is a developer adapter: the device must be paired and trusted, Developer
Mode must be enabled, a runner must be signed for the current team, and the
Developer Disk Image must be mounted. Keep its HTTP and MJPEG ports on
loopback; do not expose them on a LAN. Start the signed runner with the
project's normal XCTest device workflow, forward its HTTP port to
`127.0.0.1:8100`, then use:

```sh
swift run cmux-phone tcp-server --port 0 \
  --source wda --url http://127.0.0.1:8100
```

The printed TCP port is the agent-facing endpoint. A client should call
`device.list`, `session.open`, and `screen.snapshot` before sending an
action; the response's `screen_seq` becomes the action's `screen_seq`
precondition.

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
duplicates while the session's bounded replay cache retains the id, so a retry
within that cache window cannot tap twice. Clients may include the `screen_seq`
from the frame they used; stale coordinates are rejected and the client can
refresh before retrying. The session emits `ui.changed` after an accepted
action and includes the resulting sequence in the receipt.

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
