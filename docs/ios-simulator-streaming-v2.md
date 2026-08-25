# iOS simulator streaming v2

cmux iOS mirrors a booted iPhone/iPad Simulator hosted by the paired Mac. v2
replaces per-frame still images pushed through the shared mobile event queue
with a dedicated low-latency video pipeline. The design goal is that
interaction feels immediate (touch-to-photon bounded by one encode + one
network round trip + one decode) and that every failure an operator can cause
(transport flap, app background, simulator reboot, device switch, slow link)
recovers without user action and without cross-connection state. The one
deliberate exception: a panel that no longer exists (closed on the Mac, or
its device removed without a replacement selection) ends the stream
terminally with a `closed` state instead of retrying forever.

## Why a rebuild

The v1 pipeline sends absolute image frames through the same bounded host
event queue as all other mobile events. Under backpressure the queue sheds
frames, which required per-connection replay debt, generation fencing, stall
counters, resubscribe repair, and demand reannounce to paper over. Each of
those mechanisms exists only because stale frames can queue and be dropped
after encoding. v2 makes that state unrepresentable: frames are encoded only
at the moment the link has capacity, so there is never an encoded frame to
shed, replay, or fence.

## Invariants

1. **Latest frame wins, always.** The capture side keeps exactly one slot: the
   newest simulator frame. Encoding consumes that slot only when the transport
   has credit. Intermediate frames are skipped before encoding, never after.
2. **No shared queues.** Video runs on its own transport lane with its own
   flow control. Nothing else can starve it; it can starve nothing else.
   Input runs ahead of video, not behind it.
3. **Stateless attach.** A viewer session is created by a single `start`
   message and every stream begins with a keyframe. Any drop, at any layer,
   is recovered by sending `start` again. No handshake sequence, no state
   survives a connection.
4. **No sleeps, no polling.** Frame flow is driven by capture callbacks and
   ack arrivals. The only timer is a watchdog that detects "attached + booted
   + no frame progress" and forces a keyframe/encoder restart.
5. **Input is sacred.** Touch down/up and key events are never coalesced or
   dropped; only intermediate touch moves coalesce (newest position per
   in-flight window). Input is applied on the Mac in arrival order with a
   monotonic sequence check.

## Frame path

capture (worker BGRA ring, existing) → latest-frame slot → VideoToolbox
encoder → dedicated iroh lane → iOS VideoToolbox/AVSampleBufferDisplayLayer →
display.

- **Capture.** The existing supervised simulator worker already writes
  GPU-synchronized packed-BGRA frames into a shared-memory ring for the Mac
  pane. v2 attaches a second consumer to that ring. No new capture machinery,
  no ScreenCaptureKit, no TCC.
- **Encode.** `VTCompressionSession`, HEVC preferred, H.264 fallback.
  Real-time mode, frame reordering disabled (no B-frames), low-latency rate
  control, long keyframe interval with on-demand keyframes for attach and
  loss recovery. Bitrate adapts to the ack-measured delivery rate; resolution
  caps at the simulator's pixel size scaled to the viewer's request.
- **Pacing (encode-on-credit).** The host encodes frame N+1 only while
  `unacked_frames < window` (default 2). When the link stalls, raw frames
  keep overwriting the latest slot for free; when credit returns the newest
  frame is encoded next. Latency under congestion is bounded at ~window
  frames instead of growing a queue.
- **Decode/display.** iOS feeds sample buffers to
  `AVSampleBufferDisplayLayer` with immediate-display attachments (no
  compositor-side buffering). Decode failures request a keyframe; three
  consecutive failures restart the stream via `start`.

## Input path

Touches on the phone are forwarded raw (down/move/up, normalized 0–1
coordinates in the simulator's displayed orientation, mapped into raw HID
space on the host) and injected through the existing worker HID path, the
same one the Mac pane uses. The wire format carries pointer IDs, but the
viewer and host currently forward a single pointer; multi-touch (pinch) is a
planned follow-up on the same messages. The simulator's own UIKit performs scrolling physics, so scroll fidelity
is native by construction; nothing synthesizes wheel events. Hardware keys,
Home, lock, and rotate reuse the existing simulator control RPCs.

Input messages are tiny, sent on a reliable ordered channel separate from
video frames, flushed immediately. Move events coalesce client-side per
send-window so a fast drag cannot backlog; down/up never coalesce.

## Wire contract

A dedicated client-opened bidirectional iroh lane
(`CmxIrohLane.simulatorStream`, lane code 5, resource `simstream:<panel-uuid>`)
carrying length-prefixed binary messages (`CmuxSimulatorStreamKit`,
`SimStreamWireCodec`). Existing mobile RPC is reused only for discovery
(`mobile.simulator.list` and workspace state sync). Send priorities: Mac
video at −5 (below terminal PTY bytes at 0, above artifact bulk at −10) so
video can never delay typing; phone start/ack/input at +5.

- `start {version, epoch, max_long_side, codec_prefs}` — opens/reopens a
  stream; the host answers with `config` then a keyframe. Re-sendable on the
  same lane; a `start` on a NEW lane supersedes the panel's previous session
  (last-writer-wins ownership, so a dead connection can never hold a panel).
- `config {codec, pixel_size, display_scale, orientation, parameter_sets,
  nal_unit_header_length}` — re-sent whenever geometry or the encoder
  changes; the next frame after a config is always a keyframe.
- `frame {seq, flags(keyframe), pts_us, payload}` — HVCC/AVCC encoded video.
- `ack {seq, receipt_us}` — flow-control credit + bitrate feedback, sent only
  after the frame actually displayed.
- `input {seq, events[]}` — touch/text/key/button events (viewer → host),
  replay-guarded by the monotonic batch sequence.
- `keyframe_request {}` — decoder loss recovery.
- `stop {}` — idempotent.
- `state {status, detail}` — host status changes (never a keepalive clock).

Capability `simulator.stream.v2` is advertised by the host
(`MobileSimulatorStreamCapability.streamV2Identifier`); phones that see it
use this pipeline and gate v1 off, others keep v1. v1 host code stays until
the capability has shipped in a release, then dies.

Viewer-side quality control reuses `start`: picking a preset re-sends
`start` on the live lane with a new `max_long_side`, and the host answers
with a resized encoder, fresh `config`, and a keyframe, so quality switches
repaint in one frame with no lane or lifecycle churn. Presets cap encode
resolution only (High 2000 / Balanced 1280 / Data Saver 800 long-side
pixels); pacing already bounds latency at any resolution, so lower presets
trade sharpness for bandwidth and a slightly cheaper encode/decode, not for
responsiveness.

Device switching is discovery-plane, not lane-plane: capability
`simulator.devices.v1` advertises `mobile.simulator.devices.list` and
`mobile.simulator.device.select`. Selecting reuses the Mac pane's own
`selectDevice` path; the running stream absorbs the switch through the same
worker-restart flow as any capture change (status updates, replaced ring,
new config + keyframe).

## Lifecycle

One state machine on each side, event-driven:

- Transport drop → viewer returns to `connecting`, keeps the last frame
  on-screen dimmed, and re-sends `start` as soon as the lane reopens. The
  host destroys the session on lane close; there is nothing to reconcile.
- App background → viewer sends `stop`, tears down the decoder, keeps state
  needed to `start` on foreground.
- Simulator reboot/device switch → host emits `config` + keyframe (same
  stream) or ends the stream if the device is gone; the viewer's `start`
  epoch disambiguates stale sessions.
- Watchdog: if the host has an attached viewer and a booted device but the
  ring produced no consumable frame for N seconds, restart the worker
  attachment and force a keyframe. If the viewer has credit outstanding and
  no frame for N seconds, it re-sends `start`.
