# cmux next: the macOS host for `cmux.rd/1`

Status: implemented on branch `feat-cmux-next-rd-mac-host` (2026-10-28). Measurements are in
section 6. This file covers only the macOS host. The protocol, the session rules and the Linux
host are in [remote-desktop.md](remote-desktop.md); the plan for one remote desktop stack is in
[remote-desktop-DESIGN.md](remote-desktop-DESIGN.md).

## 1. Goal

Stream a Mac's own display to a cmux viewer with the lowest input-to-screen latency we can get
on a LAN or tailnet, and the highest frame rate the display gives, using the `cmux.rd/1` engine
that the Linux host already uses. Remote-desktop.md RD11 sets the phase order: the macOS host
comes after the Linux host.

## 2. Where each part runs

| Part | Where | Notes |
| --- | --- | --- |
| Frame gate, congestion control, FEC, packetizer, NACK history, keyframe recovery, exactly-once input | Rust, `cmux-rd-engine` and `cmux-rd-core` (unchanged, every OS) | No I/O and no OS calls |
| Wire format and control messages | Rust, `cmux-rd-proto` (unchanged) | |
| Session loop, admission, token, carriers (UDP or one TCP stream) | Rust, `cmux-rd-host` `host.rs` and `stream.rs` (shared by Linux and macOS) | `stream.rs` now drives a `Desktop` trait |
| Capture | macOS glue: `src/mac/capture.rs` (ScreenCaptureKit) | |
| Encode | macOS glue: `cmux_encode::videotoolbox::SurfaceEncoder` (VideoToolbox from an IOSurface, already used by the remote browser host) | |
| Input injection | macOS glue: `src/mac/input.rs` and `src/mac/keys.rs` (CGEvent) | |
| Decode and display | the viewer: `CmuxNextRemoteView` (Swift, VideoToolbox, IOSurface to a layer) | unchanged |

The `Desktop` trait (`src/desktop.rs`) is the only seam: `size`, `fd` (readable when there is
damage), `drain` (damage rectangles), `encode` (capture and encode one picture), bitrate, and
`inject` and `release_all` for input. The Linux code moved behind the same trait without a
behavior change (`src/x11.rs`).

## 3. Pipeline

1. **Capture.** One `SCStream` per session on one display (`--display main` or an index, left
   to right). Pixel format `420v` (NV12, video range), so the hardware encoder needs no color
   conversion. Size: the display's native pixels, fitted to 3840x2160 (H.264 level 5.2 at 60
   fps), even. `minimumFrameInterval` is 1 / `--max-fps`. The cursor is drawn into the frames.
   The queue depth is 4: the session holds the newest frame (so a recovery keyframe needs no new
   capture), and the encoder reads another.
2. **Damage.** ScreenCaptureKit sends a frame only when the display changed. Each frame's status
   is read from the frame info; frames that are not `complete` (idle, blank, suspended) are
   dropped. The frame's dirty rectangles (points) become pixel rectangles and go to the engine's
   frame gate, the same input the X damage extension gives the Linux host. A complete frame with
   no dirty rectangles counts as full-screen damage.
3. **Wake-up.** The capture callback runs on ScreenCaptureKit's queue. It stores the newest pixel
   buffer and the damage under a mutex, then writes one byte to a non-blocking pipe. The pipe's
   read end is the `fd` that the session's `poll(2)` waits on, next to the TCP control socket
   and the UDP socket. No thread polls and nothing sleeps. A full pipe already holds a wake-up,
   so no event is lost.
4. **Encode.** When the frame gate asks for a frame, the newest pixel buffer's IOSurface goes
   to VideoToolbox through `CVPixelBufferCreateWithIOSurface`. Nothing is copied on the CPU. The
   session uses low-latency rate control, real time, no frame reordering, an infinite GOP with
   an IDR on request, and a per-frame bitrate from the congestion controller. A damage hint is
   passed but unused (VideoToolbox takes none).
5. **Send.** The engine packetizes the access unit with FEC and sends it as `cmux.rd/1`
   datagrams over UDP, or framed on the control stream when the viewer has no UDP.
6. **Input.** Datagrams from the viewer carry input with sequence numbers. The engine applies
   each event exactly once and in order. The host posts it as a CGEvent at the HID tap:
   - pointer positions in stream pixels map onto the display's global points;
   - buttons use the wire numbering (1 left, 2 middle, 3 right, 8 back, 9 forward) with click
     counts for double and triple clicks (within 500 ms and 4 points);
   - scroll arrives in hundredths of a line (or of a point when precise) and carries fractions
     to the next event;
   - keys arrive as USB HID usages and leave as virtual key codes (both name physical keys, so
     the host's own layout decides the character), with modifier flags tracked from held keys;
   - committed IME text goes out as Unicode strings of at most 20 UTF-16 units per event.

   Held keys and buttons are tracked and released when control ends or input skips a gap.

## 4. Choices and why

| Choice | Why | Source |
| --- | --- | --- |
| ScreenCaptureKit, not CGDisplayStream | the supported capture API; change-driven frames with dirty rectangles and status | Apple, "ScreenCaptureKit" and `SCStreamFrameInfo` documentation |
| NV12 capture | the hardware encoder's native input; no conversion pass | Apple, `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` |
| IOSurface to VideoToolbox | no CPU copy between capture and encode | Apple, `CVPixelBufferCreateWithIOSurface`, `VTCompressionSession` |
| Low-latency rate control, no reordering, infinite GOP | each frame leaves the encoder before the next one arrives; keyframes only on loss | Apple, `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` (WWDC21 "Explore low-latency video encoding with VideoToolbox") |
| Pipe wake-up into the existing `poll(2)` loop | one event loop for sockets and capture; no threads to coordinate and no polling | POSIX `pipe(2)`, `poll(2)` |
| Datagrams with FEC and NACK, delay-based congestion control (shared engine, unchanged) | measured on the Linux host (remote-desktop.md 15.6): loss recovery sets the tail, not the codec | systematic Reed-Solomon over GF(2^8) with a Cauchy matrix; one-way delay trend from transport-wide feedback (`cmux-rd-core` `fec.rs`, `cc.rs`) |
| Settle time 0 on macOS | ScreenCaptureKit delivers whole composited frames; the Linux host waits 1 ms because an X app draws one change in several requests | measured (section 6) |
| CGEvent at the HID tap | the Mac handles it as its own keyboard and mouse, in every app | Apple, `CGEventPost`, `kCGHIDEventTap` |

## 5. Permissions and trust

- The host process, or the app that started it, needs **Screen Recording** and
  **Accessibility**. TCC follows the responsible process, so a host started from a terminal
  inside an app with both grants inherits them.
- The admission rules are those of the Linux host (remote-desktop.md 11): a per-launch token,
  loopback only by default, and a private overlay only with `--single-tenant-overlay 1`. Until
  the link token authenticates `hello` claims (remote-desktop.md 11.0), this host is a
  development host. It is not wired into the app's Share This Mac flow, which still uses
  WebRTC (remote-desktop-DESIGN.md U1, U2).
- Capture shows the cursor and every window. The redaction list for password and
  authentication windows (remote-desktop.md 4.1) is not built yet.

## 6. Measurements

See the PR description and the HTML report for the run that produced these numbers, including
both hosts on the same display and the same viewer.

## 7. Mac Screen on cmux.rd/1: the network design

Mac Screen (the device hub's host and viewer roles) moves from WebRTC to this engine. The
network layer follows five rules, so that no transport product is a design decision:

1. **Security is end to end, in the session.** The two devices run a Noise_XX handshake
   (25519, ChaCha20-Poly1305, BLAKE2s; the `snow` library `cmux-remote` already uses). Each
   side's ephemeral session key is signed by its device hub key; the other side checks it
   against the `signingKey` the hub ticket carries for the peer. Every rd datagram is then
   sealed with the session key, and one that fails to open is dropped before the engine sees
   it. Relays are untrusted pipes: they see ciphertext and cannot read, change or speak as a
   device.
2. **Carriers are interchangeable.** The session needs one thing from the network: deliver a
   datagram to the peer, best effort. Direct UDP (same network, IPv6, a punched IPv4 mapping),
   the tailnet, and relays (TURN, an iroh relay, the Durable Object relay, a relay we host) are
   implementations of that one interface. Adding or removing one changes nothing above it.
3. **Measure, do not choose.** The path selector in `cmux-transport` decides at run time:
   every known carrier is tried at once, probes inside the sealed session measure each path,
   any live direct path beats every relay, and the lower smoothed RTT wins inside a class,
   with hysteresis. Paths switch during a session without a reconnect.
4. **Policy is data.** Which relays a device may use comes from the hub ticket (the user's
   relays, and the cmux relay on a paid plan), as relay lists do today. The code prefers none.
5. **Rate control and loss recovery stay end to end.** The engine's congestion control and FEC
   adapt to whichever path is live, so no carrier must be video-grade for correctness; a
   slower path only lowers the bitrate.

The first carriers are those cmux already has: direct UDP with hole punching, the tailnet,
and the TURN servers in the hub ticket. Candidates travel over the ticket's signaling socket.

## 8. Not done

- Display switching inside a session (the host streams the display it started with).
- Audio, clipboard, cursor shape channel, HEVC negotiation.
- A signed helper with a stable TCC identity, and the app's Share This Mac switch to this engine.
- Content filters that hide password and authentication windows.
