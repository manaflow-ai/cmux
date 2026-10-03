# cmux next: remote desktop (first-party app `cmux/remote-desktop`)

Status: proposal, 2026-10-02 (lane 17, remote desktop lead). Spec owner: the coordinator; this file is the spec proposal "remote-desktop". Decided input: APPS (an extremely fast remote desktop app for macOS, Linux and Windows hosts; Rust where it wins), N13 (official apps may have a server side), SV1 to SV3 (cmux server, Postgres, health), T1 (WireGuard via Freestyle tunnels plus Durable Objects), T2 (own session by default), IOS1 to IOS3 (a rewritten iOS client is a later client of the same stream), D15/D18/D19/D20 (computer use, Windows deferred for CUA, retention, agent classes), D37/D38 (one VPC per team; same-LAN discovery for Mac-to-Mac), V2 (VM image roles, `desktop` off by default). Builds on spec/computer-use.md ("Remote view" and "Measured lessons"), spec/sync-and-transport.md sections 4 to 6, spec/network-policy.md, spec/app-platform.md, spec/identity-and-permissions.md, plans/cmux-next/transport.md (lane 12, in progress), plans/cmux-next/server.md (lane 10), plans/cmux-next/first-party-apps.md section 10 (app servers and native panes), plans/cmux-next/computer-use.md. Binding: OWNERSHIP-PRINCIPLES.md, architecture.md (0 % idle CPU, no polling), skills/cmux-next-feature. Measured numbers are in section 15; every number names its method and both ends.

## 0. Decisions in this proposal

RD1. One product, one engine. "Remote view" in spec/computer-use.md (desktop and window targets) and this app are the same thing: the `remote_view` tab kind is the app's native pane, and the producer is one Rust engine, `cmux-rd`, that runs on every host OS. Chromium tab targets stay with the browser host.

RD2. Pixels are video. The default stream is hardware H.264 or HEVC with low-latency settings (no B-frames, no lookahead, constant-quality rate control with a one-frame buffer, infinite GOP, recovery without IDR spikes). Text stays sharp through four mechanisms in order of cost: a client-sized virtual display (no scaling), grayscale text antialiasing on the producer, idle refinement (re-encode the static frame at a low QP after motion stops), and in phase 4 a lossless tile layer for static text regions. RFB-style tile encodings are not our protocol.

RD3. Damage drives everything. No damage, no capture, no encode, no packet, no wakeup. A static desktop costs 0 bandwidth and about 0 CPU on both ends. The client never runs a display link while no frames arrive.

RD4. Our own thin media protocol (`cmux.rd/1`) over the overlay (QUIC datagrams were the strongest alternative; inside WireGuard they add a second handshake, a second encryption layer and a bulk-oriented congestion controller, and give nothing the overlay lacks). WireGuard already gives encryption, peer identity, roaming and path selection (transport.md), so we add only what real-time video needs: packetization, adaptive FEC, NACK when the RTT allows it, delay-based congestion control from transport-wide feedback, pacing, and reference-frame recovery. Media and input ride unreliable datagrams inside the WireGuard session; control, cursor shapes and clipboard ride one reliable stream. We do not run QUIC or WebRTC inside WireGuard (double encryption, a second ICE, a congestion controller tuned for bulk).

RD5. Latency first, then sharpness, then containment, then frame rate (spec computer-use "Measured lessons" 4). The client presents the newest decoded frame at the next display refresh and never queues frames. There is no jitter buffer on direct paths.

RD6. The cursor is a separate channel. Capture always excludes the cursor. In control mode the client draws the native cursor locally (zero added latency) and the host sends only shape changes; in view mode the client draws the remote cursor at the position the host reports.

RD7. Hosts are off by default. Hosting is enabled per machine by a user-origin op on that machine (or by the server installer flag for headless servers and VMs). Every session needs the owner's network policy reachability, an app grant, and, unless an unattended grant covers the viewer, live consent at the host. A visible indicator on the host shows every viewer and has a Stop control that always wins.

RD8. Agents do not get remote desktop control. Agents act through computer use (`cua.act.*`, with its own audit and cursor). A `mux` principal may open a view-only pane for its user; it never receives frames itself and never injects input through this app.

RD9. Speak RFB only as a client, for compatibility with hosts we cannot install on (macOS Screen Sharing on a login window or a Mac without cmux, Linux VNC servers). Never as a server, never as our host protocol (section 12).

RD10. On macOS the host engine runs inside the separately signed screen agent helper that already owns the computer-use TCC grants, as its own process (one TCC identity for "this Mac can be seen and controlled", fault isolation between agent CUA and human streaming). Capture and input backends are shared crates used by both engines.

RD11. Phase order: Linux host (virtual X display on servers and VMs) to macOS client first, then the macOS host, then Wayland and Windows hosts, then iOS and web clients (section 17).

## 1. Goals and non-goals

Goals:
- View and control a whole desktop, one display, one window, or a virtual desktop on any enrolled machine (Mac, Linux box, Windows box, cmux server, Cloud VM, team VM) from the macOS app, later from iOS and the web dashboard.
- Feel local on a LAN: glass-to-glass p50 at or under 30 ms with hardware encode. Stay usable on WAN: p50 at or under the path RTT plus 35 ms. Never pretend a high-RTT path is interactive.
- Sharp text at the viewer's native scale; never scale a larger frame down.
- Zero cost at rest. Bounded CPU, GPU and power while streaming (section 2).
- Safe by default: default deny, consent, visible indicator, audit, no unattended access without explicit setup.
- One shared engine for hosts and for the CUA live watch, so agent GUI sessions on VMs can be watched and taken over at full rate.

Non-goals (phases 1 to 3):
- Game streaming features (relative mouse lock, gamepads, HDR). The engine does not prevent them later.
- A VNC server or any listener outside the overlay.
- Login-window and pre-login access on macOS (needs a LaunchDaemon and private APIs). The RFB client covers that case through macOS Screen Sharing.
- Multi-party control (two people driving one desktop at once). Several viewers may watch; one controller at a time.
- Web dashboard control in phase 1 (browsers cannot speak WireGuard; the DO relay path is view-only there until cost is measured).

## 2. Targets and budgets

### 2.1 Latency

Glass-to-glass (G2G) = from the client's input event timestamp to the first photon of the changed pixels on the client's display, with a reference test window on the host that redraws within 1 ms of input. Measured in product and CI by the marker method (section 15.1): the host test window draws a counter as a bit pattern; the client reads it from decoded pixels; display present and scanout are added from the client's measured presentation timestamps.

| Path | Encode | G2G p50 | G2G p99 | Notes |
| --- | --- | --- | --- | --- |
| `direct_lan` (same subnet, RTT under 2 ms) | hardware | <= 30 ms | <= 50 ms | stricter than the spec's "median input-to-paint under 50 ms" |
| `direct_lan` | software (VM, no GPU) | <= 45 ms | <= 80 ms | encode time dominates; caps fps (section 8) |
| `direct_wan`, one metro (RTT <= 20 ms) | hardware | <= RTT + 30 ms | <= RTT + 60 ms | |
| `via_cloud_region` or `do_relay` | any | <= RTT + 35 ms | labeled | above `remoteDesktop.interactiveMaxRttMs` (default 80 ms) the pane is "view only, high latency" until the user picks "Control anyway" |

Budget at 60 Hz host and 120 Hz client, hardware encode, LAN (p50 estimates to be replaced by measurements): input send and inject 1 ms; host app reacts and the host compositor composes, half a host frame on average, 8 ms; capture delivery 1 to 2 ms; convert plus encode 3 to 5 ms; packetize and send 0.5 ms; network 1 ms; reassembly and decode 2 to 3 ms; wait for the client refresh, half a client frame, 4 ms; present and scanout 4 to 8 ms. Sum: about 24 to 32 ms. The two display terms (host compose, client refresh) are about half the budget, which is why a 120 Hz host display mode (where the host has one) and presenting on the very next client refresh matter more than encoder speed.

### 2.2 Bandwidth (1920x1080, H.264 or HEVC, typical; measured values in section 15)

| Content | Target |
| --- | --- |
| Static | 0 |
| Typing, cursor blink, small UI changes | under 0.5 Mbit/s |
| Scrolling text | 2 to 8 Mbit/s |
| Full-screen motion at 60 fps | 8 to 20 Mbit/s (HEVC lower) |
| 4K full motion | 20 to 40 Mbit/s |

Default ceiling `remoteDesktop.maxBitrateMbps` = auto (congestion control decides, hard cap 80 Mbit/s); the DO relay path has its own cost cap (section 6.6).

### 2.3 CPU, GPU, power

| Side | At rest | Streaming 1080p60 motion | Notes |
| --- | --- | --- | --- |
| Host, hardware encode | 0 % CPU, 0 wakeups (capture source idle) | <= 15 % of one core plus the media engine | capture, convert on GPU or none (NV12 straight from the capture API), packetize, FEC |
| Host, software encode (VM) | 0 % | measured in section 15; fps and resolution cap so it stays under `remoteDesktop.host.maxSoftwareEncodeCores` (default 2) | |
| Client (Apple silicon) | 0 % with no frames; pane hidden pauses the stream | <= 10 % of one core at 1080p60, <= 20 % at 4K60; hardware decode | reassembly and FEC in Rust, decode in VideoToolbox, zero-copy IOSurface to the layer |
| Client power (laptop) | 0 | target <= 1.5 W above idle at 1080p60 (UNVERIFIED target, to be measured with powermetrics) | |

## 3. Architecture

```
 macOS client (cmux app)                                 host (Mac, Linux, Windows, server, VM)
 ┌─────────────────────────────────┐                      ┌──────────────────────────────────────────┐
 │ RemoteDesktopPane (Swift/AppKit)│                      │ cmux-rd host engine (Rust)               │
 │  input capture, local cursor,   │                      │  session owner (rd_session records)      │
 │  IOSurface layer, path badge    │                      │  capture backend ── damage ──▶ scheduler │
 │        ▲ decoded IOSurface      │                      │  convert (GPU/none) ─▶ encoder backend   │
 │ VideoToolbox decode (Swift)     │                      │  packetizer + FEC + pacer + CC           │
 │        ▲ access units           │                      │  input injector, clipboard, cursor       │
 │ cmux-rd client core (Rust,      │  overlay datagrams   │  consent + indicator + audit             │
 │  xcframework): reassembly, FEC, │◀════ media, input ══▶│                                          │
 │  NACK, feedback, recovery       │  overlay stream      │  macOS: inside the screen agent helper   │
 │        ▲                        │◀════ control ═══════▶│  Linux/Windows: role `desktop` of         │
 │ cmux link (WireGuard endpoint,  │  (WireGuard, any     │  `cmux host run` (lane 1/10 supervisor)  │
 │  lane 12) via local socket      │   path: LAN, WAN,    └──────────────────────────────────────────┘
 └─────────────────────────────────┘   VPC, DO relay)
```

Crates (all new, under `cmux-tui/crates/` once the prototype graduates):

| Crate | Pure? | Role |
| --- | --- | --- |
| `cmux-rd-proto` | pure | wire formats (control messages, datagram headers), golden vectors |
| `cmux-rd-core` | pure, injected clock | frame scheduler, packetizer, FEC, reassembly, NACK and recovery state machines, congestion controller, quality ladder; property tests |
| `cmux-capture` | I/O | capture and damage backends per OS (shared with cmux-cua screenshots and live watch) |
| `cmux-encode` | I/O | encoder and decoder backends per OS (VideoToolbox, VA-API, NVENC, AMF, QSV, Media Foundation, software openh264) |
| `cmux-input` | I/O | input injection, keyboard mapping, clipboard per OS (shared with cmux-cua) |
| `cmux-rd` | I/O | the host engine binary and the `cmux rd` CLI verbs mounted in the `cmux` binary |

The macOS client links `cmux-rd-core` through the client xcframework (the same one that will carry the overlay endpoint on iOS). Decode and presentation are Swift, because VideoToolbox, IOSurface and Core Animation are the platform's lowest-latency path and the pane is AppKit.

## 4. Hosts per OS

### 4.1 macOS host

- Process: `cmux-rd host` inside the screen agent helper bundle (RD10), launched by the helper so TCC attributes Screen Recording and Accessibility to the helper. A LaunchAgent; runs only while a user is logged in.
- Capture: ScreenCaptureKit `SCStream` per target (display, window, or app set), pixel format 420v or 420f (NV12, so the encoder needs no conversion; `xf44` gives 4:4:4 for the phase 4 path), `showsCursor = false`, `queueDepth` 3 (the SDK default is 8, which adds queueing), `minimumFrameInterval` = 1 / target fps (zero on a 120 Hz host display). Frames arrive only on change; `SCStreamFrameInfo` carries status (`idle` frames are dropped) and dirty rects, which feed the scheduler and the idle-refinement timer. Content filters exclude password manager and authentication windows (same list as computer-use capture redaction).
- Virtual display (client-sized rendering, lesson 2): for headless or dedicated Macs only, a virtual display at the pane's pixel size and scale. The only API is private (`CGVirtualDisplay`). Proposal: ship it behind `remoteDesktop.host.virtualDisplay` (off by default on Macs with a person at the console, on for "server" Macs), and fall back to the nearest native mode of a physical display without changing it. Never change a physical display mode while someone is at the console.
- Encode: VideoToolbox, `EnableLowLatencyRateControl`, `RealTime`, no frame reordering, H.264 High or HEVC Main, `MaxKeyFrameInterval` very large, LTR (long-term reference) frames where the OS supports them for loss recovery (section 6.4). The existing `CmuxSimulatorStreamKit` encoder already uses these settings and is the starting point.
- Input: CGEvent posting at the HID level (`kCGHIDEventTap`) from the helper (needs Accessibility). A virtual HID device (the OS sees a real keyboard and mouse) needs an Apple-granted entitlement; we apply for it early and keep CGEvent as the default. Secure input fields accept injected events, so consent covers this risk; the indicator says "controlled".
- TCC: capture outside the system picker triggers a recurring (monthly) re-consent prompt on current macOS; remote access products avoid it with a restricted Apple entitlement for persistent content capture and the separate "Remote Desktop" privacy permission. Unattended Mac hosting depends on that entitlement (DECISION in the report). Attended sessions may use the system content picker instead. The helper's signing identity must stay stable, because TCC grants follow the code signature.
- Text antialiasing: macOS has drawn grayscale antialiasing only since 10.14, so nothing to change.
- Audio (optional): ScreenCaptureKit audio capture, Opus.

### 4.2 Linux host

Three targets, in phase order:
1. Virtual X desktop (servers, Cloud VMs, team VM `desktop` role): `Xvfb` (or `Xorg` with the dummy driver when a GPU is present) at the client's size, a small window manager, `xrandr` resize on pane resize (debounced to the end of the gesture, like PTY resize). Capture: XDamage for damage, XShm `GetImage` for readback of the damaged bounding box (whole frame for the encoder, but readback only where damaged), XFixes for cursor shape and position. Input: XTest. Fontconfig `rgba=none` and `hintstyle=hintslight` inside the virtual session (grayscale antialiasing, lesson 5).
2. GPU streaming hosts (`streaming` machine class): capture as above or through the compositor; encode with VA-API (Intel, AMD) or NVENC (NVIDIA); zero copy where the capture yields a DMA-BUF.
3. A person's own Wayland desktop: xdg-desktop-portal ScreenCast plus RemoteDesktop with `persist_mode` restore tokens, PipeWire with DMA-BUF and the damage and cursor metadata, libei for input. Consent is the portal dialog plus ours. GNOME and KDE also offer headless virtual monitors, which we use for "virtual desktop" targets on Wayland machines.
- CUA shares the display: on VMs the session host owns the per-session Xvfb or nested compositor (spec computer-use); `cmux-rd` attaches to the same display, so a person can watch an agent's GUI session at full rate and take over (agent paused while a human controls, enforced by the CUA host).

### 4.3 Windows host (phase 3)

- Two processes: a service (`cmux-rd` under the `cmux server` Windows service, LocalSystem or a virtual account) and a session agent started in the active console session (`CreateProcessAsUser` with the session's token), so capture and input keep working across the secure desktop (UAC prompts, lock screen) the way Windows itself requires.
- Capture: DXGI Desktop Duplication (dirty and move rects, pointer shape separately, works on the secure desktop from the session agent) as the default; Windows.Graphics.Capture for window targets.
- Encode: Media Foundation hardware MFTs, or NVENC, AMF, QSV directly for lower latency and LTR control.
- Input: `SendInput` with scancodes from the session agent; elevated windows need the agent at a matching integrity level (UIPI).
- Virtual display: an Indirect Display Driver (IddCx) is the only supported way; it needs a signed driver. Deferred; until then, nearest native mode.
- ClearType off inside dedicated sessions only (per-session setting), never on a person's console session.

## 5. Encoding

- Codec negotiation per session: the client sends what it can decode in hardware (Apple silicon: H.264, HEVC Main/Main10; AV1 decode from the M3 generation), the host what it can encode in hardware; pick HEVC when both have it, else H.264; AV1 only when both have hardware (phase 4; no Apple chip encodes AV1 in hardware today, so a Mac host never sends AV1). The public VideoToolbox API has no HEVC 4:4:4 profile constant, although the platform's own screen sharing uses 4:4:4; whether the hardware takes `xf44` input through the public API is a test for phase 4.
- Software encode (hosts without a hardware encoder, such as Cloud VMs): H.264. The license question is open: the BSD codec built from source does not carry its vendor's patent coverage, which applies only to the vendor's separately downloaded binary; the GPL encoder needs a patent license. Proposal: on Linux hosts the `desktop` role downloads the vendor's prebuilt binary at enable time (the installer's verify-then-run rules apply), so the shipped cmux binary contains no H.264 software encoder (DECISION in the report).
- Low-latency settings on every backend: no B-frames, no lookahead, one-frame VBV or constant QP with a bitrate cap, slices sized to packets where the encoder supports it (so a lost packet costs one slice), infinite GOP.
- Recovery without IDR spikes: long-term reference frames (the encoder references the last frame the client acknowledged after a loss) where the backend supports them; else gradual intra refresh over a few frames; IDR only as the last resort or on decoder reset.
- Damage-aware scheduling: encode only frames with damage; for small damage the encoder still sees a full frame but nearly all macroblocks are skipped, which is cheap. Coalesce damage events that arrive within one frame slot.
- Idle refinement: when damage stops for `remoteDesktop.refineAfterMs` (default 120 ms), encode the unchanged frame once or twice at a low QP (P-frames, bits only where quality was lost). Text sharpens a moment after scrolling stops, at a cost of a few hundred KB once.
- Color: BT.709, full range end to end; 4:2:0 by default. 4:4:4 where both ends support it in hardware (colored text on dark backgrounds is the visible case); phase 4 lossless text tiles: the host detects static, low-color regions (text) after refinement and sends them losslessly (palette plus zstd) as an overlay layer the client composites until the region changes again.
- Content class: the scheduler classifies each second as `text` (small or scrolling damage), `motion` (large damage every frame) or `mixed`, which the quality ladder uses (section 8).

## 6. Transport (`cmux.rd/1`)

### 6.1 Channels

| Channel | Carrier | Reliability | Contents |
| --- | --- | --- | --- |
| control | one TCP stream through the overlay (link stream, `cmux.wire/1` framing) | reliable, ordered | session setup and teardown, capabilities, consent state, cursor shapes, clipboard, display list, quality reports, keyframe or LTR requests that need confirmation |
| media | overlay datagrams (UDP inside the WireGuard session, overlay port 4103, service name `remote-desktop`; 4102 is the overlay's path-probe port) | unreliable; FEC and NACK | video packets, FEC packets, audio packets |
| input | overlay datagrams | unreliable with redundancy: each input event repeats in the next three input packets until acknowledged; the host applies by sequence number exactly once | keys, pointer, scroll, text |
| cursor position | overlay datagrams | latest wins | position, visibility |
| feedback | overlay datagrams, client to host, once per frame and at least every 50 ms while streaming | unreliable | transport-wide arrival times, loss, NACK list, decode time, last presented frame, client refresh rate |

Media, input, cursor position and feedback all use overlay port 4103. Because lane 12 carries every path's traffic as WireGuard datagrams (including the DO relay), the datagram channels work on every path; the DO relay just has higher RTT and its own cost cap.

### 6.2 Datagram header (16 bytes, then payload)

`u8 version_flags`, `u8 type` (video, fec, audio, input, input_ack, cursor_pos, feedback, probe), `u16 stream` (one per display), `u32 frame`, `u16 index`, `u16 count` (data packets of the frame), `u16 fec_count`, `u16 transport_seq` (for transport-wide feedback). Datagram size: the link reports `max_datagram` for the session, fixed for the session's life and repeated in every `path.changed` event (transport.md section 12b): 1152 bytes for a session that may use the Freestyle path (hosts in a VPC), 1332 bytes otherwise. A session never re-packetizes on a path change. The packetizer sizes every video, FEC and audio packet to `max_datagram`: with the 16-byte header, a shard carries 1136 bytes (VPC hosts) or 1316 bytes (other hosts) of the frame body. Where the encoder supports slice size limits, slices are sized to one packet payload so a lost packet costs one slice. FEC parity packets have the same size as the frame's data packets. A frame body is a 16-byte prefix (`u32 au_len`, `u64 t_capture_us` host monotonic, `u32 ref_frame`, `u32::MAX` for none) followed by the access unit; the last data shard is zero-padded. `ref_frame` lets the viewer release a frame only when its reference was released (crate `cmux-rd-proto`).

### 6.3 FEC and retransmission

- FEC per frame: systematic Reed-Solomon over the frame's packets (SIMD implementation), overhead chosen from the measured loss (0 % on a clean LAN, then 10 % to 50 %), with a minimum of one parity packet for keyframes and refinement frames on lossy paths.
- NACK: the client requests missing packets when the RTT is under a frame-time budget (default: RTT < 40 ms); the host keeps the last 200 ms of packets.
- A frame that cannot be completed by its deadline is dropped; the client reports it, and the host recovers with an LTR or intra refresh (6.4). Later frames that reference a lost frame are not displayed (no corrupted frames shown).

### 6.4 Recovery

The client acknowledges complete frames in feedback. On loss, the host's next frame references the newest acknowledged long-term reference (one RTT of drops, no IDR), else starts an intra refresh wave, else sends an IDR. Decoder errors on the client always request an IDR.

### 6.5 Congestion control and pacing

- Delay-gradient bandwidth estimation from transport-wide feedback (one-way delay trend, loss), with a loss-based ceiling; decrease within 100 ms of queue growth, increase multiplicatively while the delay gradient is flat. The estimate drives the encoder's target bitrate per frame, never a send queue: if the estimate drops, the next frame gets fewer bits; queued old frames are never sent late.
- Pacing: a frame's packets go out spread over at most half a frame interval at 1.5x the estimate on WAN paths; on `direct_lan` they go out as one burst (lowest latency).
- Flow control (measured necessity, section 15.6): at most one frame in flight beyond the newest acknowledged frame on reliable carriers; on datagrams the pacer never holds more than one frame. While a frame is in flight, new damage coalesces into the next frame. Rate control is per frame (one-frame VBV); constant QP is never used for streaming.
- Probing: padding probes only while the content class is `motion` and the estimate is below the cap.

### 6.6 Paths (lane 12) and policy

- The pane shows the path badge (`direct`, `via cloud region`, `relayed`) and live RTT, loss and the measured G2G. Above `remoteDesktop.interactiveMaxRttMs` the pane is view-only until the user chooses "Control anyway" (spec computer-use lesson 3).
- One link per session: control, media and input share the viewer's one overlay link to the host (lane 12 moves paths without a reconnect). The engine subscribes to the link's path events; a path change resets the congestion controller's delay baseline and, for a relay path, applies the relay caps at once instead of waiting for the controller to find them.
- The DO relay is a weak path for video (lane 12, plans/cmux-next/transport.md section 13: same-city relay 7.8 ms p50 / 14.2 ms p99, 5 to 21 MB/s, about 4,000 messages per second per Durable Object). Relay batching is landed (transport.md section 12b: relay frame kind `datagrams`, up to 16 KiB of length-prefixed datagrams per message, about 14 media datagrams per message), so the message ceiling is no longer the video limit; the relay's byte rate (21 MB/s measured with 16 KiB messages, shared by every client of that host) and its per-message cost are. The engine hands the link one frame's packets at once so they can share relay messages. So on `do_relay` the quality ladder starts at `remoteDesktop.relay.maxBitrateMbps` (default 4) and `remoteDesktop.relay.maxFps` (default 15), prefers lower fps over lower resolution for text, and shows "relayed"; both caps are team policy values.
- The Freestyle tunnel path measured 2.2 ms p50 at 228 Mbit/s down with the in-process WireGuard engine (lane 12); every tunnel today uses one San Francisco endpoint, so users far from it pay the hairpin.
- Web dashboard (later): the HostDO application relay with WebCodecs decode; the same packets on a WebSocket; view-only first.

## 7. macOS client

- Pane: tab kind `remote_view {host, target: display:<id>|window:<id>|virtual, mode: view|control}` in the workspace store (layout record only; the stream is not stored). A native pane (`renderer: "native"`, first-party only).
- Decode: VTDecompressionSession, hardware, real-time; output IOSurface-backed NV12; frames are decoded the moment the last packet arrives and the previous undisplayed frame is discarded.
- Presentation variants (DEV switch `remoteDesktop.debug.presenter`, Lawrence picks after measurement): (A) `CALayer.contents` = the decoded IOSurface (zero copy, the window server converts color); (B) `CAMetalLayer` with `maximumDrawableCount` 2, a YUV shader and latest-frame-wins present on the next refresh; (C) `AVSampleBufferDisplayLayer` with display-immediately attachments (reported to backlog above 60 fps). Windowed composition can add a frame or more compared with a direct-to-display fullscreen surface, so the bench measures windowed and fullscreen, 60 and 120 Hz. Recommendation pending the measurement on a lit display (15.4); (B) is the default candidate because it gives explicit control of the present time with two drawables.
- No display link while idle: the pane wakes only when a frame arrives.
- HiDPI: the client asks for a virtual display at the pane's backing pixel size and scale (2x on Retina) and re-asks at the end of a resize gesture; until the host answers, the pane shows the current frame at 1:1 with padding, never scaled down.
- Input: keyboard by physical key (USB HID usage) end to end, mapped to the host's keycodes there; IME-committed text as Unicode text events (setting `remoteDesktop.keyboard.mode` = physical | text | auto). Pointer absolute, scroll with phases and precise deltas. Containment: input goes to the host only while the pane is focused; Cmd-Tab, Cmd-Space, Mission Control and cmux shortcuts stay with the viewer unless `remoteDesktop.keyboard.sendSystemShortcuts` is on; a release chord (default Ctrl-Opt-Escape, a KeyboardShortcutSettings entry) always returns the keyboard. Never fullscreen by itself; a user-initiated "Fill Window" is a normal pane zoom.
- Multi-monitor: one stream per remote display; the pane shows one display with a picker, or "All displays" as a canvas of streams; each display can open in its own tab.
- Clipboard: text and images both ways when the session allows it; files are phase 3 (they ride the `file` channel kind). macOS has no pasteboard change notification (only a change counter), and the runtime may not poll: the client checks the counter when the pane gains focus and on copy and cut key events it forwards; the host checks on the same events relayed from the client and when the remote user's paste key arrives. Recent macOS versions may show a privacy prompt for programmatic pasteboard reads; the host reads only on those events.
- Cursor: native local cursor in control mode with shapes from the host (cached by hash); remote cursor overlay in view mode.

## 8. Adaptive quality

One quality ladder, decided at the host from feedback and the content class:
1. Bitrate first (continuous).
2. For `text` content keep full resolution and lower fps (60 to 30 to 15); for `motion` content keep fps and lower resolution (100 % to 75 % to 50 % of the virtual display, which then re-renders at that size, no scaling of a larger frame).
3. Under software encode, cap fps so encode time stays under the frame interval (measured per frame), and cap cores at `remoteDesktop.host.maxSoftwareEncodeCores`.
4. Presets the user can pick: Auto (default), Sharp text (favor resolution and refinement), Smooth motion (favor fps), Low bandwidth. All values are settings with documented defaults; fine-tuning values are Debug Settings tunables (FEC overhead floor, NACK RTT limit, refinement delay and QP, pacing factor).

## 9. Audio (optional, off by default)

Opus at 48 kHz, 10 ms frames, in-band FEC, its own datagram type; capture via ScreenCaptureKit audio (macOS), the PipeWire monitor (Linux), WASAPI loopback (Windows). Played through an AVAudioEngine node on the client with a 20 ms target buffer (audio needs a small jitter buffer; video does not).

## 10. Running as a cmux app

Manifest (first-party tier, id `cmux/remote-desktop`):
```jsonc
{
  "id": "cmux/remote-desktop",
  "server": {
    "kind": "native",
    "binary": {"linux-x86_64": "bin/cmux-rd", "linux-aarch64": "bin/cmux-rd", "windows-x86_64": "bin/cmux-rd.exe",
               "macos-arm64": "helper:screen-agent/cmux-rd"},       // macOS: inside the signed screen agent helper (TCC)
    "args": ["host"],
    "catalog": "catalog/rd-catalog.json",
    "hosts": ["local", "cmux-server", "team-vm"],
    "instances": "machine",                                          // one engine per machine (first-party-apps.md 10.2 proposal)
    "data": "cache",                                                 // nothing durable but the audit tail, which is posted to TeamDO
    "activation": "onDemand"
  },
  "contributes": {
    "paneKinds": [{"id": "remote_view", "renderer": "native"}],
    "commands": ["rd.connect", "rd.disconnect", "rd.toggleControl", "rd.showHosts", "rd.host.enable", "rd.host.disable", "rd.host.stopAll"],
    "paletteScopes": [{"id": "remoteDesktop", "title": "Remote Desktop"}],   // lists machines with the desktop capability, path badge and RTT
    "sidebarSections": [{"id": "desktops"}]                                    // optional section: machines and active sessions
  }
}
```

- Host role: on Linux and Windows the engine is the `desktop` role of `cmux host run` (lane 1 supervisor, lane 10 roles; V2 says `desktop` is off by default). `cmux server up --desktop` or `cmux rd host enable` turns it on; the team VM can enable it per team policy. On macOS the app's "Allow Remote Desktop to This Mac" toggle (Settings and palette) starts the helper's engine.
- Directory: the host record in `TeamDO` gains `capabilities.desktop {targets, encoders, max_fps, virtual_display, gpu}` so clients list only reachable desktops.
- T2: the remote desktop pane does not need a cmux-tui session on the host; it talks to the host's `desktop` role over the overlay. The host's session host is not involved (it owns PTYs only).
- cmux server (lane 10): servers expose the role; health (SV3) adds "display asleep" and "no GPU encoder" signals. Team VM: no GPU, software encode with the caps in section 8; its main use is watching and taking over agent GUI sessions.

### 10.1 Ownership

| Entity | Owner | Writers |
| --- | --- | --- |
| `rd_session {id, host, target, viewer {user, install, client}, mode, consent_ref, path, started_at, ended_at, end_reason, counters}` | the host engine on that machine | viewers through ops (start, stop, request control); the host user (stop, revoke); the engine (end on timeout or policy) |
| host desktop policy (enabled, allowed principals, unattended grants, consent timeout, clipboard policy) | the host engine on that machine, mirrored to `TeamDO` for display | user-origin ops on that machine; team admins may restrict, never widen |
| `remote_view` tab record (host, target, mode preference) | workspace store | user ops |
| pane view state (scale fit, keyboard capture, display picker selection) | the client | that client |
| audit events | the host engine, then the `TeamDO` audit chain (E9) | append only |

### 10.2 Ops (catalog) and surfaces

| Op | Risk | Surfaces |
| --- | --- | --- |
| `rd.session.start {host, target, mode, idempotency_key}` -> `{session, channel ticket}` | `execute` (control) or `read` (view) | palette "Connect to Desktop…", sidebar machine context menu "View Desktop" / "Control Desktop", CLI `cmux rd connect <host> [--display N] [--view]`, MCP `remote_desktop_open` (opens a view-only pane for the user, never focuses, mux class only) |
| `rd.session.stop {session}` | `mutate-own` | pane toolbar, tab context menu, host indicator, palette, CLI `cmux rd stop`, MCP |
| `rd.session.list {host?}` | `read` | CLI `cmux rd ls --json`, MCP, sidebar section |
| `rd.control.request {session}` / `rd.control.release` | `execute` | pane toolbar, shortcut (KeyboardShortcutSettings), palette, CLI |
| `rd.host.enable {targets, unattended?}` / `rd.host.disable` | `mutate-own`, user origin on that machine only | Settings, palette, CLI on that machine; exempt from MCP (reason: hosting is a human decision) |
| `rd.host.grant {principal, mode, expires}` / `rd.host.revoke` | `mutate-own`, user origin with re-authentication | Settings, CLI on that machine; exempt from MCP |
| `rd.host.stop_all` | `mutate-own` | host indicator (menu bar), palette, global shortcut |
| `rd.audit.list {host, since}` | `read` | Settings, CLI, MCP |
| `rd.bench {host, workload}` | `read` | CLI and Debug menu (DEV/NIGHTLY) |

The CLI verbs go through a request file (lane rule: the Swift CLI is frozen): `.cmux-scratch/nx-worker/cli-requests/remote-desktop.md`.

## 11. Security

- Reachability: hosts listen only on the overlay (no public or LAN port). The team network policy (spec/network-policy.md) must allow the viewer's device to the host's overlay port; a new tag `tag:desktop` lets admins write `{"src": ["autogroup:member"], "dst": ["autogroup:self:remote-desktop"]}` style rules. Network policy gives reachability only.
- Authorization (default deny, checked by the host engine on every `rd.session.start`): allow only if (a) hosting is enabled on that machine, (b) the viewer's principal is the host's owner user from their own interactive client (`autogroup:self`), or holds a host grant from the owner, and (c) the agent class rules allow it (agents: never control; `mux` may open a view-only pane for its own user, which streams to the user's client, not to the agent).
- Consent: if anyone other than the requesting user is logged in at the console, or the host owner set "Ask every time", the host shows a consent panel at the top center of the active screen, no default button (Allow view, Allow control, Deny; deny after 30 s). Control is a separate consent from view. A viewer can hold control only while the consent stands; the person at the host can take control back by moving the mouse (configurable) and always by Stop.
- Indicator: while any session exists, the host shows a non-dismissable indicator: on macOS a menu bar item plus a thin colored screen-edge border and a pill "Viewed by <name>" / "Controlled by <name>" with Stop (the system's own capture indicator also shows and cannot be hidden); on Linux desktops the portal's indicator plus ours; on headless hosts no local indicator exists, so every start posts a feed item to the host owner. Stop ends every session at once and wins over any viewer op.
- Unattended access: only by explicit setup on the host machine: `rd.host.grant {principal, mode, expires}` (user origin, Touch ID or password re-authentication, feed notification to the owner, audit); own-user unattended grants never expire, grants to other people expire (default 30 days, renewable). Team admins can forbid unattended grants by policy. Headless servers and VMs: the installer flag `--desktop` enables owner-only access; other principals still need a grant.
- End-to-end encryption: WireGuard end to end on every lane 12 path including the DO relay (it carries ciphertext). Web clients are the exception (TLS ends at Cloudflare), which is why web stays view-only first.
- Clipboard: off for other people's sessions by default, on for own devices; every transfer is audited as type and size, never content.
- Audit: session start and end, consent decisions, control grants and releases, clipboard and file transfers, policy changes; stored by the engine and appended to the `TeamDO` audit chain; visible in Settings and `cmux rd audit`.
- Secure content: the capture excludes password manager and authentication windows on macOS (content filter list shared with computer use); on Linux and Windows nothing comparable exists, which the consent panel states.

### 11.0 Phase-1 trust gap (binding until lane 12's link token)

The landed host engine (`cmux-tui/crates/cmux-rd-host`) trusts the principal claims in its `hello` because the overlay link token does not exist yet. So, by coordinator decision (2026-10-03): the host binds loopback and refuses every non-loopback peer by default; only the explicit `--single-tenant-overlay 1` serves a private single-tenant overlay; the Mac `remote_view` pane is not exposed in Release builds and says "development only" where a connection is made. Lift these limits only when the link `hello` carries a verified token and the host checks it.

### 11.1 Remote relay analysis (required by the repo's remote relay rules)

- Local command or content execution: control-mode input is code execution on the host by design (a viewer can type into a terminal). It is therefore `execute` risk, allowed only for the host's owner user from their own interactive clients or a principal the owner granted at the host with re-authentication, never for agent principals, and always visible on the host indicator. View mode executes nothing. No `rd.*` op carries a command, path or URL parameter; `target` is a display or window id from the host's own list, validated by the host.
- Access to unowned objects: a session is bound to `(viewer principal, install, host, target)` at start; every datagram and control message is accepted only on that WireGuard peer and session id; a viewer cannot address another viewer's session, and `rd.session.stop` from a viewer stops only that viewer's session (the host user stops all). Window targets are limited to the windows of the host's console user.
- Local state exposure: the host returns only the display and window list (titles redacted unless the viewer may control), never files, environment or process lists; clipboard flows only when the session's clipboard policy allows it, and it is audited.
- Policy tests (required with the implementation): agent principals are refused for control; a viewer cannot stop or join another viewer's session; a revoked grant ends its sessions within one feedback interval; Stop on the host ends every session and no media datagram is sent after it; ops arriving over the relay without a valid `hello` principal are refused.

## 12. Interop with RFB (VNC)

Decision RD9: a Rust RFB client (protocol 3.8; Raw, CopyRect, ZRLE, Tight; Apple's authentication type for macOS Screen Sharing; VNC authentication only over the overlay or tailnet) runs in the client's host process and renders into the same pane, labeled "compatibility". Why: it gives access with nothing installed on the host (any Mac with Screen Sharing on, including the login window, which our engine cannot reach; Linux machines that already run a VNC server; the team's Mac fleet), at a cost of one small crate. Why not more: RFB is tile-based and lossless-first, so it is slow for motion and cannot reach the latency targets; vendor fast modes are not open to third-party clients; a VNC server would add a listener and weak password authentication, so we never host RFB. Connections still need the network policy and are audited.

## 13. What we reuse

- `CmuxSimulatorStreamKit` (Swift): VideoToolbox encoder settings, credit gate, bitrate controller, wire codec ideas; the iOS `CmuxMobileBrowserStream` display-link and frame-sequence policies for the later iOS client.
- cmux-cua (Rust): ScreenCaptureKit and X11 capture, CGEvent and XTest input, cursor overlay; moves into `cmux-capture` and `cmux-input` so both engines share them.
- `cmux-wg` and lane 12's `cmux-transport`: the overlay endpoint, paths and path stats.

## 14. Verification

- Pure core: property tests for the packetizer and reassembly (any loss pattern within FEC capacity reconstructs the frame; frames never display out of order; a frame that references a lost frame never displays), the congestion controller against a simulated path (queue delay bounded under a step capacity drop; recovery time), and input exactly-once under duplication and loss.
- A TLA+ model of the session and consent lifecycle: no frame is sent after Stop or after consent is revoked; control is never held without consent; a kicked viewer receives nothing after `rd.session.stop`.
- Bench: `cmux rd bench` (section 15.1 method) in CI on two machines per release (Linux host on a Freestyle VM, macOS client on a fleet Mac) records G2G, bandwidth and CPU per workload and fails on regressions over 20 %.
- Visual: screenshots of the pane variants, the host indicator, the consent panel (DEV switch per variant), Reduce Motion and Reduce Transparency, `appearance.borders = none`.

## 15. Prototype and measurements

Code (throwaway, branch feat-cmux-next-remote-desktop): `experiments/remote-desktop/rdhost/` (Rust Linux host and Linux test client, built on a Blacksmith Testbox), `experiments/remote-desktop/rdclient-mac/` (Swift macOS client and VideoToolbox self test), `experiments/remote-desktop/rdpane-variants/` (UI variants, section 15.5). Wire protocol: a measurement-only framing on one TCP stream (no FEC, no congestion control, no flow control).

### 15.1 Method

- Glass-to-glass by marker: a test window on the host draws a 16-bit counter as black and white cells; the counter increments on each key press. The client sends one key at t0 and stops the clock when a decoded frame shows the expected counter (read from the decoded luma plane). One sample at a time, 300 samples per run, a random 40 to 160 ms gap between samples. The number ends at the decoded frame in client memory: display present and scanout are NOT included (headless client machines).
- Host stages (input inject to damage, readback, convert, encode) are host-clock stamps in each frame header; the client maps them with the clock offset of its lowest-RTT ping.
- Workloads: `marker` (only the counter changes), `text` (a full screen of text scrolling one line every 33 ms), `motion` (a full-screen moving gradient plus moving random noise every frame; nearly incompressible, a stress test), `idle` (30 s, no input).
- Capture modes: `damage` (capture only after a damage event, coalesced to at most 60 fps) and `poll` (full screen at 60 fps).
- Host: Freestyle VM, 4 vCPU AMD EPYC Zen 3 at 2.45 GHz, no GPU, Ubuntu 24.04, Xvfb 1920x1080 (and 2560x1600 on loopback), XDamage + XShm readback of the damaged box + XTest input, software H.264 (two encoders compared, constant QP 24 unless stated, one thread). 2026-10-02 13:20 to 14:12Z.

### 15.2 Linux host to macOS client over the cloud path (the end-to-end prototype)

Client: fleet Mac mini, Apple M4 Pro, macOS 26.5.1, load 4 to 6, hardware H.264 decode (VideoToolbox, real time). Path `via_cloud_region`: mini in Santa Clara -> userspace WireGuard (pinned `cmux-tui wg hub`, TCP only) -> Freestyle tunnel endpoint in San Francisco -> team VPC -> host VM. Idle RTT p50 7.2 ms. Host encoder: the BSD encoder in screen-content mode.

| Workload, capture | G2G p50 / p95 / p99 ms | lost | Mbit/s | fps | client decode p50 ms | host capture->encoded p50 ms | client CPU % of a core | host process CPU % of a core |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| marker, damage | 24.1 / 32.9 / 69.8 | 1/300 | 0.0015 | 7.4 | 2.4 | 12.8 | 0.7 | 9.4 |
| marker, poll | 28.4 / 39.0 / 41.7 | 2/300 | 0.007 | 60 | 1.6 | 9.7 | 4.1 | 81.8 |
| text, damage | 51.1 / 89.9 / 109.7 | 1/300 | 1.35 | 34.7 | 1.6 | 25.0 | 2.6 | 103.7 |
| motion, damage (constant QP, no rate control) | 236 / 309 / 353 | 7/300 | 84.8 | 9.3 | 8.1 | 57.7 | 4.8 | 62.1 |
| idle 30 s, damage | n/a | n/a | 0 | 0 | n/a | n/a | 0.01 | 0 |
| idle 30 s, poll | n/a | n/a | 0.006 | 60 | 1.6 | n/a | 4.0 | 78.0 |

Second round (14:15 to 14:24Z, per-sample data): 2560x1600 marker 36.8 / 52.6 / 74.6 ms (host encode 23.5 ms; the client side did not change), 2560x1600 text 81.2 / 143.3 / 376.1 ms (host encode 39 ms, 23 fps). A 1080p marker repeat had the same p50 (23.4 ms) but a p95 of 114 ms: every slow sample was in host-to-client delivery, clustered near 240, 460 and 730 ms, and a host TCP trace matched them to retransmission timeouts (200 ms minimum, then doubling) after single lost downlink packets: a lone small frame gets no duplicate acknowledgements, so TCP cannot fast-retransmit it.

Median marker sample: input to host damage 4.4 ms (one network leg plus inject), damage to capture 0.2 ms, encode 12.8 ms, encoded to client receive 3.8 ms, receive to decoded 2.5 ms. The host software encoder is the largest stage. The client side is 1.6 to 2.5 ms. Most runs had one sample near 900 to 1000 ms on the input leg (cause UNVERIFIED; candidates: a retransmission timeout in the hub's userspace TCP, or the first input after a test app respawn).

### 15.3 Linux host, in-VPC (the "LAN-like" path) and loopback

In-VPC: a second VM in the same VPC as client (2 vCPU, software decode), RTT p50 0.6 to 1.0 ms. 300 samples each, 0 losses, 1920x1080.

| Encoder | Workload | G2G p50 / p95 / p99 ms | Mbit/s | fps | host encode p50 ms | host process % of a core |
| --- | --- | --- | --- | --- | --- | --- |
| GPL encoder, fastest preset, QP 24 | marker | 7.9 / 10.1 / 11.1 | 0.005 | 9.1 | 4.2 | 4.7 |
| BSD encoder, camera mode | marker | 9.3 / 11.1 / 11.6 | 0.006 | 9.3 | 5.1 | 4.9 |
| BSD encoder, screen mode | marker | 14.7 / 18.8 / 19.6 | 0.005 | 8.6 | 9.4 | 9.1 |
| BSD encoder, screen mode | text | 30.2 / 43.8 / 50.5 | 1.36 | 44.9 | 20.1 | 96.5 |
| GPL encoder, fastest, QP 24 | text | 30.9 / 60.0 / 72.2 | 182 | 46.7 | 9.9 | 68.0 |
| GPL encoder, fastest, 8 Mbit/s, one-frame VBV | text | 22.1 / 34.0 / 37.3 | 5.4 | 47.2 | 10.6 | 72.1 |
| GPL encoder, fastest, 8 Mbit/s, one-frame VBV | motion | 25.2 / 35.5 / 39.0 | 6.9 | 57.7 | 8.2 | 75.9 |
| GPL encoder, fastest, QP 24 | motion | 128.7 / 315.5 / 344.3 | 219 | 48.6 | 14.1 | 102.4 |
| BSD encoder, screen mode | idle, damage | n/a | 0 | 0 | n/a | 0.2 |
| BSD encoder, screen mode | idle, poll | n/a | 0.029 | 60 | 8.3 | 75.0 |

Pipeline floor (loopback on the host VM, marker, damage): 6.5 ms p50 (GPL encoder) to 8.1 ms (BSD camera mode) to 15.8 ms (BSD screen mode). Inject to damage 0.4 to 0.6 ms, readback of the damaged box 0.1 ms, color conversion 0.05 ms; the encoder is 60 to 80 % of the floor. At 2560x1600 encode time grows 1.4x to 2.2x (marker p50 13.5 to 24.1 ms), and the 4 vCPU VM cannot keep up with full-screen text scroll at that size in any mode.

### 15.4 macOS encode and decode (no network, no capture)

Fleet mini, M4 Pro, macOS 26.5.1, 600 frames per row, frames drawn into the encoder's IOSurfaces (ScreenCaptureKit not measured), low-latency rate control, real time, hardware required.

| Size | Codec | encode p50 / p99 ms | decode p50 / p99 ms | text kbit/s at 60 fps | motion kbit/s at 60 fps |
| --- | --- | --- | --- | --- | --- |
| 1920x1080 | H.264 | 4.6 to 5.4 / 5.2 to 8.5 | 1.0 to 1.2 / 1.7 to 2.4 | 1475 | 7650 |
| 1920x1080 | HEVC | 5.0 to 5.8 / 5.6 to 8.9 | 0.8 to 1.4 / 1.4 to 3.2 | 1327 | 7628 |
| 2560x1600 | H.264 | 8.4 to 9.3 / 8.7 to 12.9 | 1.7 / 2.9 to 3.6 | 1250 | 7998 |
| 2560x1600 | HEVC | 9.1 to 10.0 / 9.5 to 13.6 | 1.3 to 1.7 / 2.7 to 3.0 | 1071 | 7894 |

No AV1 encoder exists in VideoToolbox on M4 Pro (macOS 26.5.1) or M5 Pro (macOS 27.0.1). At 2560x1600 the real-time encoder dropped 1 to 19 of 600 back-to-back frames (cause UNVERIFIED). A loopback run on the mini with a VideoToolbox test host (no capture) gave G2G p50 9.7 ms (8.6 ms with full-range output, which saves a range conversion in the decoder). Presenter variants A to C and display latency are UNVERIFIED (no lit display).

### 15.5 UI variants (screenshots for Lawrence)

PNGs in the lane's private scratch directory (`ui-variants/`, index.md lists each): pane chrome A (hover toolbar), B (status strip), C (no chrome, tab context menu), dark and light; states (connecting, view only on a high-latency relay with "Control Anyway", waiting for consent, disconnected by a person, host stopped sharing); host indicator I1 (screen-edge border plus pill), I2 (pill only), I3 (menu bar item and menu); the host consent panel; Japanese checks. The screenshots are self-rendered by the demo (this shell has no screen capture grant), so Liquid Glass is shown in its opaque fallback. Recommendation: chrome A, with the same actions in the tab context menu; indicator I1 while anyone has control, I2 while view only, I3 always while any session exists; consent as a floating panel at the top center of the active screen, no default button.

### 15.6 What the measurements change in the design

1. Damage-driven capture is confirmed: idle is 0 bytes and 0.2 % of a core; polling costs 75 % of a core and adds about 8 ms p50 (a wait for the next slot). RD3 stands.
2. Per-frame rate control is mandatory. Constant QP with incompressible content saturated the CPU and the path (85 to 219 Mbit/s) and raised the RTT from 7 to 80 ms; with an 8 Mbit/s, one-frame VBV the same content ran at 7 Mbit/s with G2G p50 25 ms. Section 6.5 rate control is not optional.
3. Flow control is mandatory: with no limit on frames in flight, frames queued in the send buffer and latency grew to 300+ ms. Rule added: at most one frame in flight beyond the newest acknowledged frame on reliable carriers, and on datagrams the pacer never queues more than one frame; new damage coalesces into the next frame meanwhile.
4. The encoder dominates the host budget. Hardware encode on a Mac takes about 5 ms at 1080p; the best software encode on a 4 vCPU VM 4 to 10 ms, the screen-content software mode 9 to 20 ms. Encoders take no dirty-rectangle hint, so a 640x32 change costs a full-frame encode. Phase 1 picks the software encoder per content class (marker-like small changes and motion: the fastest preset with a one-frame VBV; scrolling text: screen-content tools) or one encoder with both properties (DECISION below).
5. The client is cheap: 1.6 to 2.5 ms receive-to-decoded and under 5 % of one core in every non-stress run.
6. A cloud-path G2G of 24 ms p50 with software encode and a 7 ms RTT meets the section 2.1 target for `via_cloud_region` (RTT + 35 ms) before display time; adding a display refresh and present (about 8 to 12 ms at 120 Hz, UNVERIFIED) keeps it inside. The hardware-encode LAN target of 30 ms p50 is consistent with the loopback 9.7 ms VideoToolbox number plus capture and display, but it is UNVERIFIED until a macOS host with ScreenCaptureKit and a lit client display are measured.
7. The key code namespace must be explicit (USB HID usage, section 7); the size in the hello is a request the host may refuse (it answers with the real size); host CPU percentages state their scale.
8. The tail on a real path is set by loss recovery, not by the codec: one lost packet of a small frame cost 240 to 730 ms over TCP (retransmission timeout). This is the measured reason for RD4: media on datagrams with FEC, NACK within the RTT, and "resend the newest frame state" instead of waiting for the lost one; on a TCP carrier (phase 1 fallback, DO relay) the engine sends a tiny follow-up packet after each frame (a tail-loss probe) so the receiver acknowledges and the sender can fast-retransmit.
9. Session teardown through the userspace WireGuard hub can lose the FIN (the host kept a dead session); the engine uses keepalive and a user timeout, and the question goes to lane 12.

## 16. Settings (all documented, defaults tested against docs)

`remoteDesktop.quality` (auto | sharpText | smoothMotion | lowBandwidth), `remoteDesktop.maxFps` (auto = client display rate), `remoteDesktop.maxBitrateMbps` (auto), `remoteDesktop.codec` (auto | h264 | hevc | av1), `remoteDesktop.resolution` (matchPane | hostNative), `remoteDesktop.keyboard.mode` (auto | physical | text), `remoteDesktop.keyboard.sendSystemShortcuts` (false), `remoteDesktop.clipboard` (ownDevicesOnly | always | never), `remoteDesktop.audio` (false), `remoteDesktop.interactiveMaxRttMs` (80), `remoteDesktop.showPathBadge` (true), `remoteDesktop.relay.maxFps` (10), `remoteDesktop.relay.maxBitrateMbps` (4), `remoteDesktop.refineAfterMs` (120), host side `remoteDesktop.host.enabled` (false), `.consent` (askOthers | askAlways), `.consentTimeoutSeconds` (30), `.takeBackOnLocalInput` (true), `.virtualDisplay` (auto), `.maxSoftwareEncodeCores` (2), `.indicator.style` (border+pill | pill | menuBarOnly; DEV variants for Lawrence to pick).

## 17. Build order

0. Prototype and measurements (this lane, done in this pass; section 15).
1. Phase 1: `cmux-rd-proto` and `cmux-rd-core` (pure, property tests); Linux virtual X host (Xvfb, XDamage, XShm, XTest; VA-API when a GPU exists, else openh264); macOS client pane with variants A to C; control channel on the overlay stream; media on overlay datagrams once lane 12 exposes them (until then, media on the stream with the same packets and no FEC); owner-only access; bench in CI.
2. Phase 2: macOS host in the screen agent helper (ScreenCaptureKit, VideoToolbox, CGEvent), consent panel, indicator variants, unattended grants, audit to `TeamDO`, clipboard, cursor channel, multi-monitor, HiDPI virtual displays on server Macs; RFB client.
3. Phase 3: Wayland hosts (portals, PipeWire, libei, virtual monitors), Windows host (service plus session agent, Desktop Duplication, hardware MFT/NVENC/AMF/QSV), audio, file transfer, iOS client (IOS1 app, same core), web dashboard view-only.
4. Phase 4: 4:4:4 and lossless text tiles, AV1, IddCx virtual displays on Windows, multiple simultaneous viewers with presence and kick (U6 rules).

## 18. Risks and open questions

- The macOS virtual display API is private and may break with an OS update; the fallback is nearest native mode with letterboxing.
- Software encode on VMs without a GPU may not reach 60 fps at 1080p within the core budget; the ladder lowers fps for text content (measured in 15).
- TCC on macOS: Screen Recording re-consent prompts on newer macOS versions may interrupt unattended hosts (research private notes; to verify on a test Mac with a lit display).
- Fleet minis are headless, so client present and scanout latency cannot be measured there; a lit test display (or a human-run bench on a laptop) is needed for the last two budget terms.
- Freestyle VM path RTT depends on the region placement of the team VPC and the user (network-policy.md latency section).

## 19. Questions for other lanes

Lane 12 (transport):
1. An unreliable datagram service on the overlay for app flows (UDP inside the WireGuard session to overlay port 4103, service `remote-desktop`), offered by `cmux link` to local processes (a Unix datagram socket or a shared-memory ring), with a priority class for real-time media over bulk streams. Until it exists, phase 1 runs media on the link's TCP stream with the flow control of section 6.5.
2. The effective inner MTU per path (direct, `via_cloud_region` with WireGuard inside the tunnel's 1280, `do_relay`), exposed to the sender.
3. Path events and live stats per link (path type, RTT, jitter, loss, path changes) as a subscription, so congestion control resets on a path change and the pane shows the badge.
4. Answered (transport.md 12b): relay batching is landed, up to 16 KiB of datagrams per relay message.
5. May a second signed process of the same user (the macOS screen agent helper, which hosts this engine) use the user's `cmux link` endpoint through its socket, or does it need its own WireGuard key (one key, one live session)?
6. Answered (transport.md 12b, 99ca23d8102): a lost FIN is resent, and a close lost at tunnel shutdown is resent after shutdown (end seen after 410 ms). Still open: Nagle default of the in-process TCP stack.
7. Host listen port policy: is any overlay port of a host reachable once the peer map allows the pair, or should apps register ports so the policy can name them? Answered in part: remote desktop is service `remote-desktop` on port 4103.

Lane 10 (server) and lane 1 (VM image):
8. A `desktop` role in `cmux host run` (off by default; `cmux server up --desktop`), with the packages it needs in the image (Xvfb or a headless compositor, a small window manager, fonts with grayscale antialiasing), and health signals "no hardware encoder" and "display asleep".
9. Linux software encoder delivery: the role downloads the codec vendor's prebuilt binary at enable time (verify-then-run), if Lawrence picks that option.
10. Windows: the service plus per-session agent model (section 4.3) inside `cmux server`'s Windows service.

Lane 3 (app platform):
11. `server.instances: "machine"`, a per-platform binary map whose macOS entry points into a signed helper bundle (TCC), `paletteScopes` contributions, and native pane kinds mounted in phase 1 for first-party apps.

Computer use lead:
12. One screen agent helper on macOS hosting both engines; shared `cmux-capture` and `cmux-input` crates; the `remote_view` tab kind owned by this app; "take over": the CUA host pauses an agent's session while a human controls the same display.

Identity, backend and enterprise:
13. `rd.*` ops in the catalog with their risk classes; `tag:desktop` in the network policy; host desktop capabilities in the `TeamDO` directory; remote desktop audit events in the `TeamDO` audit chain; a team policy key to forbid unattended grants.

iOS (lane 14): 14. The client core (`cmux-rd-core`) in the client xcframework for a later iOS client.

## 20. Decisions

Coordinator, 2026-10-02: D-RD1, D-RD3, D-RD4, D-RD5, D-RD6 and D-RD7 are accepted as recommended. D-RD2 waits for Lawrence. Update 2026-10-03: Lawrence approved D-RD2; the request text is drafted for him to submit (lane 17 private notes); nothing is submitted by agents.


- D-RD1 Software H.264 encoder for hosts without hardware encode: (a) the GPL encoder linked into `cmux-rd` (GPL-3.0-or-later compatible; best measured latency and, with per-frame rate control, the best text scroll; patent license question), (b) the codec vendor's prebuilt BSD binary downloaded at enable time (patent coverage only for that binary; screen mode is slow and forces IDR on large changes), (c) hardware-only hosts. Recommendation: (a) for phase 1 dogfood, decide (a) or (b) before any public release after a patent review.
- D-RD2 Apply now for the restricted macOS entitlements (persistent content capture; virtual HID device). Recommendation: yes, approval is reported to take months and unattended Mac hosting depends on it.
- D-RD3 The private macOS virtual display API for client-sized rendering on server Macs. Recommendation: yes behind a capability check, off on Macs with a person at the console.
- D-RD4 Pane chrome A, B or C and host indicator I1, I2 or I3 (section 15.5). Recommendation: A, and I1 + I2 + I3 by state.
- D-RD5 Agents never control through this app (RD8). Recommendation: yes; agents use computer use.
- D-RD6 RFB as client only (RD9). Recommendation: yes, phase 2.
- D-RD7 The host consent prompt is a floating panel at the top center of the active screen (not a sheet on a cmux window), with no default button, so Return cannot grant control. Recommendation: yes.
