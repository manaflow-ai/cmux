# cmux next: remote tab step r2 (macOS server host)

Status: plan, 2026-10-06, remote tab lead. Decisions (umbrella, 2026-10-06): design approved (C++ shim behind a C ABI, Rust owns session, encoding and transport); B4 approved (own workspace); B1: build on a fleet Mac with `cmux-ci run --class isolated`, run the prebuilt binary on cmux-lawrence-2; B5: the cmux.19 release asset (sha256 ddbe20e2b475baf33d0c07a2d629cd95fea844e5e804a9d70a0f755c2f22c7be). Parent: remote-tab.md, remote-tab-r1.md, remote-tab-protocol.md. Fork side done: manaflow-ai/cef `cmux/8037-remote` (RP1-RP9 green on macOS arm64, job 529b32b2f2868c1541d4b4d3; `cmux_rp_*` API 19, renumbered at landing in cmux.19).

## 1. Shape

```
cmux-remote-browser-host (macOS app bundle; Rust main)            viewer (Rust loopback first, then the app)
  libcmux_rb_shim (C++, links the CEF fork)                          cmux-rd-ffi / cmux-rd-engine receiver
    CEF init, Chrome-style CefWindow + CefBrowserView per tab          reassembly, FEC, feedback
    handlers (SHIM-HANDLERS sink "remote") -> rb control             VideoToolbox decode (Swift, D-RT-RD1)
    cmux_rp_capture_start -> frame callback (IOSurface)              PNG writer (loopback), present (app)
  Rust: session (session.rs), menu tokens (menu.rs),
        input map (rp_input.rs, landed), frame pacing
  encoder: cmux-encode VideoToolbox (lane 17, C7)  <-- IOSurface in
  transport: cmux-rd-engine source on port 4103, service "rb/1" (C1), input tag (C2)
```

- The C++ shim exists because CEF's browser process needs CefApp handlers, CEF views delegates and the `CefAppProtocol` NSApplication; the r1 harness (`tests/cmux_embedder`) already does exactly this and passes. The shim is that code without the checks, behind a small C ABI: `rb_shim_run(config, callbacks)` (blocks on the main thread), `rb_shim_open_tab(url, w, h, scale)`, and calls the Rust side for frames, titles, menus, dialogs and surfaces. Rust never touches CEF types.
- Every input call from the viewer goes through `rp_input::map_input` (landed 582e9269fb9, vectors `schemas/remote-tab/input-mapping.json`) and runs on the CEF UI thread through one `CefPostTask` trampoline in the shim.
- Native UI: the shim's menu, dialog, file and permission handlers produce rb messages; tokens follow `menu.rs` (`schemas/remote-tab/menu-token.json`); the SHIM-HANDLERS decision makes the shared handler set (browser lead v3) the source, with the remote sink in this host.

## 2. Measurements (on cmux-lawrence-2, the only GUI host)

- Input-to-paint: the viewer sends a key at t0 (viewer clock); the page paints a marker; the viewer decodes the frame whose pixels show the marker (marker method of remote-desktop.md 15.1). Report p50/p95 over 200 keys. Needs C8 (clock offset) for one-way splits; the round-trip total does not.
- Idle: 0 frames and 0 encoder calls over 60 s on a static page; host CPU from `ps -o %cpu` of the host and helper PIDs (the host starts them; it kills only those PIDs). With RP3 (`--cmux-remote-begin-frames`) the viewer issues begin frames only while `cmux_rp_needs_begin_frames` says so.

## 3. Blockers and requests (need the coordinator)

| # | Need | Why | Owner |
| --- | --- | --- | --- |
| B1 | A sanctioned way to build a macOS Rust binary and run it in a GUI session | `cmux-tui-rust-check.sh` steps build and test the cmux-tui workspace on fleet Macs but have no GUI session; cmux-lawrence-2 has the GUI session but no cargo (rule); CEF needs a GUI session | CI lead: a ci-step class `gui` on cmux-lawrence-2 that builds with cargo at low priority, or a fleet artifact step (`cmux-tui-rust-check.sh build-bin <crate>` uploading the binary) plus a GUI run step |
| B2 | `cmux-encode` VideoToolbox encoder that takes a CVPixelBuffer/IOSurface (BGRA or NV12) and a damage hint | today's `H264Encoder` in cmux-rd-host takes I420 (CPU); converting a BGRA IOSurface to I420 on the CPU every frame is the copy remote-tab RT3 forbids | lane 17 (C7 `cmux-encode`) |
| B3 | `cmux-rd-engine` source API: register a service source ("rb/1"), send frames per stream, receive service input events (C2) and rb control JSON (typed control C7 has `Control` for rd; rb messages ride as service control) | the host must not copy the carrier | lane 17 (C7) |
| B4 | Window for a new crate `cmux-remote-browser-host` (macOS-only bin, own workspace like cmux-rd-host so CEF and the shim never enter the cmux-tui Cargo.lock) | new crate | coordinator |
| B5 | CEF_PATH on the build machine: the fork artifact (job 529b32b2...) unpacked where the build step can see it, pinned by sha256 | the shim links the fork | CI lead |

## 4. Order

1. Done: input mapping (`rp_input.rs`), red first.
2. Shim C ABI header + C++ (from the harness), red embedder-style test: open a tab, get a frame through the Rust callback. Needs B1, B4, B5.
3. Host session loop: `session.rs` effects -> shim calls; frames -> encoder (B2) -> rd source (B3).
4. Loopback viewer (Rust, cmux-rd-ffi receiver + VideoToolbox decode through the app's Swift path is D-RT-RD1; for the loopback the viewer writes the decoded IOSurface as PNG) on the same machine over loopback.
5. Input back (C2 tag carries `rp_input` events), menus and dialogs (rb control), measurements (section 2).

## 5. API shapes requested from lane 17 (B2, B3)

Against the landed `cmux-rd-engine` (3ee5cf1a4b1: `MediaEngine`, `EncodeRequest`, `Encoded`, `Output`) and `cmux-encode` (`H264Encoder` over `I420`). Names are proposals; the semantics are the need.

### B2: encode an IOSurface without a CPU copy (`cmux-encode`, macOS)

```rust
// cmux_encode::videotoolbox (macOS only)
pub enum SurfaceFormat { Bgra, Nv12 }          // the fork captures BGRA today (RP2)
pub enum ColorTag { Srgb, DisplayP3 }           // REMOTE-TAB-R1: P3 tagged, sRGB fallback
pub struct SurfaceFrame {
    pub io_surface: *mut core::ffi::c_void,     // IOSurfaceRef; the caller keeps it alive until encode returns
    pub format: SurfaceFormat,
    pub width: u32,                              // pixels; a size change recreates the session inside
    pub height: u32,
    pub color: ColorTag,
}
pub trait SurfaceEncoder: Send {
    /// Wraps the surface (CVPixelBufferCreateWithIOSurface, no copy), encodes it with the
    /// existing low-latency settings and returns when the access unit is in `out`
    /// (Annex-B, SPS/PPS before every IDR, as `H264Encoder`). After it returns the caller
    /// releases the capture lease (cmux_rp_frame_release). `damage` is a hint (frame pixels).
    fn encode_surface(&mut self, frame: &SurfaceFrame, damage: Rect, force_idr: bool,
                      pts_us: i64, out: &mut Vec<u8>) -> Res<bool>;   // true = IDR
    fn set_bitrate(&mut self, kbps: u32);
    fn kbps(&self) -> u32;
}
```

The Linux host keeps `H264Encoder` over `I420` (CPU frames from the fork, `prefer_gpu = 0`); a `bgra_to_i420` that takes the fork's stride is enough there.

### B3: one rd session per peer with several streams and an rb service channel (`cmux-rd-engine`)

1. Streams: a remote tab has the page (stream 0) and popup surfaces (RP7, one stream each, opened and closed at run time). One congestion controller and pacer per peer (REMOTE-TAB-R1). Request: `MediaEngine::add_stream(stream: u16, width: u32, height: u32)`, `remove_stream(stream)`, `damage(stream, rect, now_us)`, `encoded(stream, ...)`, and `EncodeRequest.stream`; the bitrate split across streams is the engine's (page first, surfaces small). Per-stream feedback and recovery are C6.
2. Service control: rb messages (`schemas/remote-tab/messages.json`) ride the rd control stream as typed passthrough: `Control::Service { service: String, body: serde_json::Value }` (C7 typed control), routed by the hello `service` (C1). The engine or carrier hands them to the source unchanged and never parses them.
3. Service input: `InputEvent::Service(Vec<u8>)` (C2) applied exactly once and in order, delivered in `Output.inject`; the host decodes it to `cmux_remote_browser::proto::InputEvent` and calls `rp_input::map_input`.
4. Begin-frame timing (RT12): C8's `offset_us` and `rtt_us` exposed to the source, so `rb.vsync` (viewer clock) converts to host time.
5. Idle: `next_deadline_us()` returns `None` when nothing is pending, so the host's loop sleeps on the frame callback and the socket only (0 wakeups while the page is idle).
