# Phone surface: one iPhone tab, three backends

Status (2026-10-20): phases 1-3 done (Simulator and real iPhone over simctl/devicectl,
recordings, Send to Chief, live Simulator screen and input, `cmux phone` CLI/MCP;
Android follows `simulators-DESIGN.md`). Phase 4 (live USB view of a real iPhone)
is not started. Phase 5 (vphone-cli VM) stays gated on the user's go-ahead.
Owner module: `Packages/macOS/CmuxNext/Sources/CmuxNextPhone` (+ `CmuxNextPhoneTests`).
Request: an actual iPhone mirrored into cmux, driven by people and agents,
with one-click "record and send as product feedback".

## Goal

One `phone` surface that shows an iPhone screen in a pane tab, takes touch and
keyboard input, takes screenshots, records clips, and is drivable from the
palette, the `cmux phone ...` CLI and MCP. The same surface works with three
backends; the user picks a device, not a backend.

| Mode | Backend | Screen | Input | Screenshot | Record | Logs |
|---|---|---|---|---|---|---|
| Simulator | `xcrun simctl` (+ SimulatorKit for live frames/HID, phase 2) | phase 1: still frame refreshed after every action; phase 2: live IOSurface | phase 1: URL open, text via pasteboard, buttons none; phase 2: Indigo HID taps/swipes/keys | `simctl io <udid> screenshot` | `simctl io <udid> recordVideo` (SIGINT stops) | `simctl spawn <udid> log stream --style ndjson` |
| Real iPhone (USB / Wi-Fi) | `xcrun devicectl` + CoreMediaIO | live over USB via the CoreMediaIO screen-capture device (public, AVCaptureDevice `.muxed`); still frames over Wi-Fi | none: Apple offers no public input to a real device (UI-test runner bridge is a later option) | `devicectl device capture screenshot` | `devicectl device capture screen-record` (.mp4, SIGINT stops) | app console via `devicectl device process launch --console`; full syslog not public |
| iOS VM (vphone-cli) | client of the user-installed `vphone-vm` local API (`--api-listen 127.0.0.1:0`, bearer token) | `/v1/host/screen` WebSocket, pull model, HEVC/H.264 access units | `input.tap/swipe/drag/type/key/button` RPC | `screen.screenshot` RPC | cmux-side: decode the screen stream into an AVAssetWriter | `logs.syslog`, `logs.crashes` RPC |

Gated: the VM mode waits for the user's go-ahead on the external tool
(https://github.com/Lakr233/vphone-cli). Simulator mode, real-device
capture and recording come first.

## vphone-cli facts (studied 2026-10-19)

- MIT license. Swift/Xcode project (VPhoneKit, VPhoneDaemon, VPhoneLaunchpad).
  Distributed as a notarized Launchpad zip on GitHub Releases; VMs in `~/.vphone/`.
- Boots iOS (26, now 27) in Virtualization.framework PCC research VMs: Launchpad
  downloads IPSWs, patches the boot chain, restores, boots. Open boot ROMs
  (OpenAVB, OpenSEP) for new VMs.
- Host must be a physical Apple Silicon Mac on macOS 15+, with
  `csrutil enable --without debug` and `csrutil allow-research-guests enable`
  from Recovery, plus an AMFI bypass. 64 GB disk per VM.
- Automation: guest daemon `vphoned` on VSOCK 1339, exposed by the host with
  `--api-listen host:port`; per-launch 32-byte hex token (`Authorization: Bearer`,
  `?token=`, or WebSocket subprotocol `vphone-token.<token>`); `/v1/rpc`,
  `/v1/events`, `/v1/host/screen` (pull one frame per text request; binary reply =
  LE u32 header length + JSON header + length-prefixed NALs).

Decision: **depend, do not vendor.** cmux never ships vphone-cli, its ROMs or its
patches, and never changes SIP/AMFI. cmux detects an installed `vphone-cli`
(PATH, `~/.vphone`), launches `vphone-cli vm launch <name> --api-listen
127.0.0.1:0` (or attaches to a running one the user names), and talks to the
public local API with a client written from the API document. The client is our
own code, so no MIT text is copied; `THIRD_PARTY_LICENSES.md` still lists
vphone-cli as an optional external tool with its MIT notice. Host setup is the
user's action (Recovery-mode commands); cmux shows the steps and a "not set up"
state, it never runs them.

## Model (CmuxNextPhone, no daemon import)

- `PhoneDevice` value: `id` (`sim:<udid>`, `dev:<udid>`, `vm:<name>`), `name`,
  `mode`, `model`, `osVersion`, `state` (shutdown / booting / booted /
  unavailable(reason)), `screen` (`PhoneScreenGeometry`: points, scale, corner
  radius) looked up from the shared device presets (below).
- `PhoneBackend` protocol (`Sendable`): `devices()`, `boot`, `shutdown`,
  `screenshot(to:)`, `startRecording(to:) -> PhoneRecordingHandle`,
  `send(PhoneInput)`, `logs() -> AsyncThrowingStream<PhoneLogLine>`,
  `capabilities(for:) -> PhoneCapabilities` (what this device can do; the UI
  hides what is missing instead of failing).
- `SimctlPhoneBackend` (actor) over an injected `PhoneCommandRunning` seam;
  tests pass a fake runner and parse real `simctl list -j` / `devicectl list
  devices -j` fixtures.
- `PhoneRecorder` (actor): one recording = video (backend) + input events that
  went through cmux (`events.jsonl`, each with time offset from start, point in
  device points, kind) + device log (`log.ndjson`) + `notes.md` +
  `manifest.json`. Folder: `~/Library/Application Support/cmux/phone-recordings/<id>/`
  (injected root). Stop = SIGINT to the capture process, then wait for its exit
  (simctl and devicectl both finalize the file on SIGINT).
- `PhoneFeedbackClip`: the finished folder plus a Markdown summary
  (device, OS, duration, tap count, last error lines from the log, the user's
  notes) that the App layer posts into the Home chat as one message with the
  video and a poster screenshot attached. One click: "Send to Chief".
- `PhoneSurfaceModel` (`@MainActor @Observable`): selected device, latest frame,
  recording state, last error; actions call the backend; never polls. Phase 1
  refreshes the still frame after each action and on an explicit refresh;
  phase 2 replaces it with a frame stream.

## Shared device presets (with a129)

a129 owns `cmux-tui-core/data/emulated-devices.json` (browser device emulation,
208 devices, sources). The phone surface reads the same file through the daemon
(`browser.devices.list`) for the device frame (CSS viewport, DPR, corner radius
when present) and matches a simulator/device model by name ("iPhone 16 Pro").
No second device table: `PhoneScreenGeometry` falls back to the pixel size the
screenshot reports when a model is not in the presets.

## Surfaces (one action path each)

Actions (registered once in the action catalog, `cli: true`, palette-visible):
`phone.open` (pick device, open phone tab beside), `phone.boot`, `phone.shutdown`,
`phone.screenshot`, `phone.record.start`, `phone.record.stop`,
`phone.feedback.send` (stop + send clip to Chief), `phone.input.tap`,
`phone.input.swipe`, `phone.input.text`, `phone.openurl`, `phone.list`.
CLI: `cmux phone open|boot|shutdown|list|screenshot|record|stop|feedback|open-url|paste|tap|swipe|type|button|rotate|ui|logs|install|launch|appearance|locale|location` (two words each)
maps 1:1 onto those actions (Rust CLI forwards to `action.run`). MCP: the same
actions appear in the `phone` tool family through the action catalog, so agents
drive the phone exactly like a person.

## Phases

1. (done) Module, Simulator backend over simctl, device list, screenshot,
   recording bundle with event log and device log, feedback clip summary,
   tests with fake runner. Real-device screenshot/record via devicectl in the
   same backend shape.
2. (done) Live Simulator frames + HID input through SimulatorKit (private framework,
   dlopen'd; behind a capability check, falls back to phase 1).
3. (done) Phone tab in the App layer (AppKit view: device frame + screen layer, click =
   tap, drag = swipe, typing = keys), palette/CLI/MCP wiring.
4. (not started) Real iPhone live view over USB (CoreMediaIO), Wi-Fi stills.
5. (gated) vphone-cli VM backend (after user confirmation): API client, screen stream
   decoder (VideoToolbox), input RPC, recording by writing the stream.

## Non-goals / rules

- Never change SIP, AMFI, boot args or install vphone-cli for the user.
- No polling: frames come from events (phase 2 stream, phase 1 after actions).
- No synthetic system input (CGEvent) to drive Simulator.app.
- Recording never leaves the Mac except when the user clicks Send (Home chat).
