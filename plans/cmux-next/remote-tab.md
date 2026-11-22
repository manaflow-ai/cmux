# cmux next: remote browser tabs

Design proposal, 2026-10-04. Owner: browser use + computer use + Cloud umbrella owner (session cmuxterm-hq-a9). Status: proposal for the spec (coordinator imports it). Inputs: Lawrence 2026-10-04 (verbatim intent: a remote tab streams frames from Chrome, "mightyapp style", feels like a local browser, Cmd-click, every shortcut, native context menus, microphone and camera just work, Chrome extensions and "everything" work, runs on a user's `cmux server` Mac mini or a cmux Cloud VM, first principles best performance, Rust first, Swift only where AppKit requires, cookie/localStorage sync), decisions CLOUD-*, CURSOR-*, RD1-RD8 (`remote-desktop.md`), transport.md, browser-host.md, automation-lease.md, agent-cursor.md, OWNERSHIP-PRINCIPLES.md. Research: four agent reports of 2026-10-04 (pipeline, native feel, transport, code map), summarized in section 12.

## 1. Decisions in this proposal

| Id | Decision |
| --- | --- |
| RT1 | A remote tab is a browser tab whose page runtime runs on another machine. It is not a new tab kind. The tab record gains `runtime_host` (`local` or a machine id). Every browser op, the automation lease, the agent cursor and the browser host work on it unchanged. |
| RT2 | Engine on the server: full Chrome layer (Chrome-style CEF from our fork, so extensions, password manager, autofill, DevTools, permission model and profiles are Chrome's), run with no visible window, with a fork patch set called **remote presentation** (section 4). Not Alloy off-screen rendering (no extensions), not a headful window captured from a virtual display (extra copy, no damage, Chromium-drawn menus). This is the Mighty approach: fork Chromium and hook the render and UI pipelines directly. |
| RT3 | Target architecture: **split compositor** (section 1a). The server runs Blink, layout, script and raster; the Mac runs the compositor. Scroll, pinch, compositor animations and video playback happen on the Mac at display rate with no network round trip. Stage 1 ships the frame path (whole-frame video from Viz with damage rects, zero-copy into the encoder, idle = 0 CPU) because the split compositor reuses it for video-like layers and as the fallback. |
| RT4 | Pixels: hybrid. Video (HEVC or H.264) for motion; when a region stops changing for about 150 ms, the server sends that region again as lossless tiles (zstd or QOI over the BGRA/YUV444 surface), so static text is pixel-exact at the viewer's native scale. Encode size is always the pane's backing pixel size. 4:4:4 video is used where the bench (section 9) proves a hardware 4:4:4 encode and decode path; otherwise 4:2:0 video plus lossless tiles. Draw-command streaming (Cloudflare NVR style) is rejected for now (version-locked Skia on the client, font and image shipping, security boundary, patent risk). |
| RT5 | Native UI from data, not pixels: context menus, `<select>`, JS dialogs, beforeunload, file choosers, downloads, permission prompts, color picker, print, find, cursor shape, tooltips, status URL, IME composition rects. The server ships the model; the Mac shows NSMenu, sheets, panels and NSCursor; the choice returns with a token. Chrome UI that has no data model (extension action popups, autofill and password dropdowns, omnibox-free bubbles that pages trigger) is streamed as a **popup surface**: its own small video stream placed by the client as a native borderless child panel at the anchor rect. |
| RT6 | Transport: `cmux.rd/1` over the cmux-wg overlay (RD4); a remote tab is one more rd source. Control (input, menus, dialogs, clipboard, files) on the reliable ordered channel; video, audio and pointer moves on datagrams. No WebRTC, no QUIC. |
| RT7 | Agents drive a remote tab with `browser.*` through the browser host on the runtime host (CDP into the same Chrome), under the automation lease. Agents never use the rd stream (RD8). The viewer draws the agent cursor client-side from relayed `automation.input` (CLOUD-WATCH). |
| RT8 | Cloud agent browser = remote tab (Lawrence, 2026-10-04). This supersedes the browser part of CLOUD-BROWSER-DISPLAY: the virtual display (Xvfb or cua-compositor) runs only when an agent uses CUA on non-browser desktop apps. Also supersedes "chrome-headless-shell" in plan-server.md for user-visible tabs; headless shell stays only for agent-only throwaway sessions. |
| RT9 | Profiles: the profile lives on the runtime host. Cookie, localStorage, IndexedDB and extension sync between the Mac's local profile and a remote profile is a per-site, user-granted, revocable sync owned by the profile owner on each machine (section 7). |
| RT10 | Fonts: the user approves a one-time install of the Mac's system fonts onto their own server or VM (copied from their Mac by cmux, user-initiated, so the user does it for themselves); fallback metric-compatible fonts. Seamless: one prompt at first remote tab. |

| RT11 | Browser chrome is local: tab strip, omnibar, suggestions, history, bookmarks, find bar, site settings and the lease badge are cmux's native UI on the Mac (zero latency). Only page content is remote. Mighty streamed a whole Chrome window; we do not. |
| RT12 | Frame timing is driven by the viewer: the client sends its display-link timing; the server's begin-frame source (fork patch, external BeginFrameSource) produces frames phase-aligned so a frame arrives just before the viewer's vsync. Saves up to one frame interval of queueing. 120 Hz ProMotion viewers get 120 Hz begin frames when the server can sustain them. |
| RT13 | Media passthrough: a `<video>` or WebRTC remote track whose compressed stream the client can decode (H.264, HEVC, VP9, AV1 on Apple Silicon) is forwarded as the original bitstream into a video layer on the Mac (no server decode and re-encode, full quality, no added generation loss). DRM (Widevine) content falls back to server decode plus capture. |
| RT14 | Everything we own may be patched where that is the principled fix (Lawrence, 2026-10-04): the Chromium/CEF fork, cmux-rd, cmux-wg, cmux-cua, the app. Each patch states the problem it removes and lands with a test. |

## 1a. Split compositor (the "feels local" design)

Why: in whole-frame streaming every scroll, pinch and hover-free animation costs a network round trip plus encode and decode; on a 30 ms WAN path a scroll lags visibly, and text smears during motion. Chromium already separates the main thread (Blink, layout, paint record, raster) from the compositor (layer tree impl, scroll offsets, transforms, animations, drawing quads). Google's Blimp project (2015-2017) remoted exactly this boundary for Chrome on Android, but sent Skia pictures for raster on the client (abandoned; reasons not public, guess: client raster complexity and maintenance). We remote the same boundary, but the server rasters:

- Server: Blink and cc main side run normally; raster happens on the server at the viewer's device scale into tiles (GPU raster on a Mac server, software raster on Linux). The fork serializes the committed layer tree (layers, property trees: transform, clip, effect, scroll; scroll offsets and limits; compositor animations and scroll timelines; tile coverage) and the changed tiles.
- Wire: layer tree commits as deltas on the ordered channel; tiles as lossless or near-lossless tile payloads (static content) and as per-layer video streams for layers that change every frame (canvas, WebGL, server-decoded video, large animated content). Tiles beyond the viewport are prerastered and sent ahead in priority order (the same interest-area logic cc uses for tiling), so local scroll has content ready.
- Client: a Rust compositor (`cmux-rb-compositor`, Metal through objc2) holds the layer tree and tile textures, applies scroll, pinch, fling momentum, overscroll and compositor animations locally at display rate, and draws into the pane's CAMetalLayer. Scroll offsets go to the server as input (with the authoritative offset owned by the client while a gesture is active, then reconciled), so Blink's scroll events, sticky positioning and scroll-driven layout run on the server and their results arrive as the next commit.
- Main-thread-bound interactions (typing, clicks that change DOM, hover styles) still cost one round trip plus raster; on a LAN that is within the 40 ms budget, and the caret and selection highlight are drawn by the client from the latest commit so caret blink and selection drag stay local where the state allows.
- Fallback: any surface the split path cannot express (popup surfaces at first, unusual layer types, DRM video) uses the stage-1 frame path inside the same pane.
- Ownership: the client compositor owns only view state (local scroll during a gesture, animation clocks); the server owns DOM, layout and the committed tree. One writer per entity holds: the scroll offset has one writer at a time (client during an active gesture, server otherwise), handed over by an explicit message.

Stage plan: stage 1 whole-frame (r1-r2) proves the fork's windowless Chrome style, capture, transport and native UI; stage 2 split compositor (r9) replaces the content path for normal pages. The bench (section 9) must show stage 2 beating stage 1 on scroll input-to-paint and on bitrate before stage 2 becomes default.

## 2. Ownership

| Entity | Owner (single writer) | Notes |
| --- | --- | --- |
| Tab record incl. `runtime_host`, URL, title, profile | workspace store | `tab.create {kind: browser, runtime_host}`; moving a tab between hosts is `tab.close` + `tab.create` with a storage handoff, never a live migration |
| Page runtime (Chrome browser, WebContents, history, crash state) | remote browser host on `runtime_host` | `cmux browser host` role `remote` (new); one Chrome process tree per profile on that host |
| Profile data (cookies, storage, extensions, passwords) | remote browser host on that machine | sync is ops between owners, section 7 |
| Stream session (encoder state, viewport size, viewers) | remote browser host | viewer size rule: smallest visible viewer (U6) |
| View state (scroll of the pane, zoom of the pane, popup placement) | the viewing client | |
| Automation lease | browser host on `runtime_host` | unchanged |
| Agent cursor drawing | viewing client (`CmuxAgentCursor`) | from relayed events |

The relay rule from the cmux-next CLAUDE.md applies: `remote.*` runtime commands on a tab are default-deny; the owner's own clients and `mux` principals are allowed (D20); the written relay analysis ships with the first slice.

## 3. Process and code split (Rust first)

```
server (Mac mini cmux server or Linux Cloud VM)
  cmux host run
    browser role:  cmux-browser-host (Rust)            agent ops, lease, REPL, CDP driver (existing crate)
    remote role:   cmux-remote-browser (Rust, new)     session, stream, native-UI model, files, clipboard, audio, sync
                     └ C ABI ─ libcmux_rb_shim (C++, fork CEF Chrome style + remote presentation patches)
                     └ encoders: VideoToolbox (Mac, objc2-video-toolbox), x264/openh264 (Linux), lossless tiles
                     └ media in: cmux Remote Camera/Mic virtual capture devices (fork)
client (cmux macOS app)
  cmux-rd-core + cmux-rb-client (Rust, linked through cmux-rd-ffi)   transport, decode scheduling, tile compositing math,
                                                                       audio jitter buffer, key routing decision, menu/dialog
                                                                       token state, upload/download streaming, cursor cache
  CmuxNextRemoteBrowser (Swift, thin)    one NSView (NSTextInputClient, events, trackSwipeEvent, dragging), the present
                                         layer (CAMetalLayer, newest frame wins, display-link paced), NSMenu, NSCursor,
                                         sheets and panels, popup-surface panels, NSAccessibilityElement adapters,
                                         AVFoundation/ScreenCaptureKit capture, ASAuthorization passkeys
```

Swift holds no session logic, no protocol state machine and no policy. The decode call is Rust (objc2 VideoToolbox) producing IOSurfaces; Swift only sets layer contents.

The local in-app CEF tab (windowed Chrome style, browser.md decision 2) is unchanged. A remote tab on the same Mac (runtime_host = this Mac) is not offered.

## 4. Fork patch set "remote presentation" (manaflow-ai/cef)

1. Windowless Chrome style: a Chrome-style browser hosted on a hidden widget (Linux: Ozone headless platform; Mac: an off-screen NSWindow that never orders in), frames exported from Viz `FrameSinkVideoCapturer` with update rects, shared texture on Mac (IOSurface), CPU or dmabuf on Linux.
2. External UI delegates: context menu model (reuse the local shim's JSON and token protocol), external popup menus for `<select>` (as Mac Chromium does), JS and beforeunload dialogs, file chooser, download, permission prompt, color chooser, print to PDF, find; every Chrome bubble or popup widget without a data model is exported as a popup surface (its own frame sink, anchor rect, size).
3. Input: macOS edit commands carried with key events (Cmd-C/V/Z, Option-arrow, Emacs keys, DefaultKeyBinding) on Linux; scroll phase and momentum; pinch gesture events; overscroll report for swipe navigation; Cmd-click disposition on Linux; IME composition API parity; macOS user agent and client hints from the viewer.
4. Media: "cmux Remote Camera" and "cmux Remote Mic" capture devices fed by the remote browser host; audio output tap (planar float PCM with pts); screen-share source fed by the viewer's ScreenCaptureKit picker.
5. WebAuthn relay to the viewer (origin shown by the client; ASAuthorization with Apple's web-browser public-key-credential entitlement, which we apply for).
6. Web notifications to the viewer (UNUserNotificationCenter), clicks back.
7. Accessibility tree export (diffed) for VoiceOver.

Each patch lands with a Chromium-level test in the fork and a conformance case in section 9.

## 5. Input and native feel (contract summary)

- Keys: the client runs the existing KeyRouter first. cmux-reserved shortcuts never leave the Mac. Other shortcuts go to the page first; the client runs the menu action only on `key_unhandled`. Every repeat is forwarded; the server never repeats. IME through composition messages; dead keys are composition.
- Pointer: moves coalesced to the frame rate, never across a button change; click count; precise scroll with phases; pinch; force click Look Up locally from selection text; cursor shape from the server (custom cursors cached by hash).
- New tabs and windows: `open_tab {url, disposition, opener}` creates a remote tab in the cmux layout on the same runtime host (opener kept on the server).
- Clipboard: the client pushes clipboard contents on the ordered channel before Cmd-V and before a menu Paste; server copies arrive as pasteboard writes. No continuous mirroring.
- Files: upload by streaming into a per-tab server staging dir; downloads stream into ~/Downloads with quarantine and WhereFroms; drag in and out with file promises.
- Audio: Opus 48 kHz, 10 ms frames, in-band FEC, client jitter buffer about 20 ms; late video drops, audio never.
- Mic and camera: captured on the Mac (echo cancellation on the Mac, Apple voice processing), sent as media datagrams, fed to the fork capture devices; permission requires both the cmux site permission and macOS TCC on the viewer.
- HiDPI and resize: server screen info = viewer's scale and screen; resize coalesced; the last frame stretches until the new size arrives.

## 6. Latency budget (targets, verified by the bench)

| Stage | Mac server LAN | Linux VM |
| --- | --- | --- |
| input to server | 1 ms | RTT/2 |
| Chrome input to frame | 8-16 ms | 8-16 ms |
| capture | ~1 ms (IOSurface) | 2-4 ms (CPU) |
| encode | 3-5 ms (VideoToolbox) | 5-12 ms (x264) |
| network | ~1 ms | RTT/2 |
| decode | 2-4 ms | 2-4 ms |
| present | 0-16 ms | 0-16 ms |
| total | median < 40 ms | median < 40 ms + RTT |

Acceptance (Leo's lessons, computer-use.md): median and p95 input-to-paint, text sharpness at native scale (pixel diff of static text after top-off = 0), containment (never grabs input outside the focused pane). FPS is a diagnostic only. Above 80 ms RTT or on a relayed path the pane says so and stays usable for reading; control stays enabled (a browser is usable at higher RTT than a desktop).

## 7. Profile and storage sync (RT9)

- Each machine owns its profiles. A remote tab uses a profile on its runtime host: by default the workspace's agent profile there (agent tabs) or the user's "remote" profile (user tabs).
- Sync is a typed op stream between the two profile owners, per site (eTLD+1), user-granted and revocable from the lease badge or site settings:
  - cookies: live, both ways, from the Chrome cookie change listener; conflict = newest by last-update time; partitioned and HttpOnly cookies included; never across a user's two different accounts without a prompt.
  - localStorage and sessionStorage: on change (storage events through the fork), both ways.
  - IndexedDB and Cache Storage: snapshot on first grant and on tab move; not live (size, schema).
  - Extensions: the remote profile installs the same extension set as the local profile (ids from the local profile, installed from the store on the server); extension state is per machine.
  - Passwords: passkeys stay on the Mac (relay, section 4.5); saved passwords sync through the cmux password lane's store, never as files.
- Seamless default: the first time a user opens a site in a remote tab that they are signed in to locally, cmux offers "use your signed-in session here" once; yes = cookie push + live sync for that site.
- Order (CLOUD-LOGIN): sign in through the remote tab; per-site sync from the Mac; passkey relay.

## 8. Agent use and cursor

Unchanged contracts: the browser host on the runtime host publishes `automation.input` from `gate.rs driver_call`; the remote browser host relays it to every viewer of that tab with the stream; the viewer maps viewport CSS px to pane points (the remote viewport equals the pane) and animates `CmuxAgentCursor`. User input from any viewer is `user_input` for the lease (pauses the agent). Hidden or unviewed remote tabs: edge indicator (CURSOR-HIDDEN).

## 9. Tests and bench (must not slow CI)

- Required CI (seconds): Rust unit tests of `cmux-remote-browser` protocol reducers, key mapping tables (dom_code to XKB, edit commands), tile codec round trips, sync conflict vectors (`schemas/remote-tab/vectors.json`), and the Swift view's pure mapping tests. No browser launch.
- Non-required hosted Linux job (`remote-tab-headless`, under 5 minutes, path-filtered): builds nothing heavy; runs the prebuilt fork Chrome (cached artifact) under the remote presentation mode with a loopback viewer in Rust: conformance cases for menus, select, dialogs, file upload, download, clipboard, IME composition, Cmd-click, extension popup surface, cookie sync. Promoted to required only after one green week and the coordinator's OK.
- Fleet bench on cmux-lawrence-2 and a Cloud VM (scoreboard, nightly): input-to-paint median and p95 with marker frames, text sharpness diff after top-off, CPU per tab idle and scrolling, bitrate, and A/B of 4:4:4 vs 4:2:0+tiles. Results go into this file.
- GUI e2e (cmux-lawrence-2 only): a tagged app opens a remote tab to a Cloud VM and a fleet Mac, drives the native menu, select, Cmd-click, paste, upload and mic paths through the debug socket, and records screenshots.

## 10. Steps

| Step | Content | Owner | Needs |
| --- | --- | --- | --- |
| r0 | This proposal into the spec; RT1 tab record field; relay analysis | umbrella | coordinator, store window |
| r1 | Fork: windowless Chrome style + Viz capture with damage (Mac IOSurface, Linux CPU); loopback Rust viewer writes PNGs | remote tab lead (new) + CEF crash lead review | fork build slot |
| r2 | `cmux-remote-browser` crate: session, rd source, VideoToolbox and x264 encode, lossless tiles; client decode + present in CmuxNextRemoteBrowser | remote tab lead + lane 17 review (rd reuse) | cmux-tui crate slot |
| r3 | Input, cursor, IME, keys, Cmd-click, clipboard | remote tab lead | |
| r4 | Native menus, select, dialogs, files, downloads, permissions, popup surfaces (extensions) | remote tab lead | |
| r5 | Audio out, mic, camera, screen share | remote tab lead | |
| r6 | Profile sync (cookies, storage, extensions), fonts prompt | remote tab lead + password lane | |
| r7 | Cloud: server role in the cmux-next VM image (cmuxnp-* only), agent browser = remote tab, CUA display only on demand | umbrella + Cloud lead v2 | image pipeline slot |
| r8 | WebAuthn relay, notifications, accessibility | remote tab lead | Apple entitlement |
| r9 | Split compositor: fork layer-tree and tile export, `cmux-rb-compositor` (Rust, Metal), local scroll/pinch/animations, media passthrough (RT13), viewer-driven begin frames (RT12) | remote tab lead + a compositor lead (new) | fork build slot, bench proof |

## 11. Risks

- Windowless Chrome style is not supported upstream; the patch set is ours to rebase on every Chromium roll (Mighty's cost too). Mitigation: keep patches small and behind one `remote_presentation` switch, with fork tests.
- Linux no-GPU cost: Chrome software raster plus x264 at Retina pane size is an estimated 3-6 vCPU while scrolling (unmeasured). The bench decides frame-rate caps per plan.
- Freestyle Chromium sandbox under the full Chrome layer is unverified (chrome-headless-shell ran sandboxed).
- Extension UI that draws outside data models is streamed, so it looks like Chrome, not like macOS.
- Mighty's lesson: parity work (downloads, audio, webcam, YubiKey, scrolling) is the hard part, not the codec; this plan budgets steps r3-r8 for it.

## 12. Research summary (2026-10-04)

- Pipeline: zero-copy damage-driven capture, VideoToolbox low-latency rate control on Mac, x264 ultrafast zerolatency on Linux; client presents newest frame on CAMetalLayer (AVSampleBufferDisplayLayer adds queueing latency); Rust can do all VideoToolbox work through objc2-video-toolbox. Mighty: forked Chromium on GPU servers, custom protocol, shut down because M1 removed the speed gap and parity work was large.
- Native feel: CEF handler map for every item in section 5; local shim already serializes context menus with a token protocol.
- Transport: RD4 `cmux.rd/1` over cmux-wg already has GCC-style congestion control, FEC, one-frame-in-flight flow, acknowledged input; audio, mic, camera and multi-viewer are not built; relay path today is DO relay with caps; spec conflict on own relays (plan-transport.md line 14 vs sync-and-transport.md 6.1) needs a coordinator decision.
- Code map: `remote_view` tab exists as a DEBUG browser-record URL (`cmux://remote-view`), with `RemoteViewStreamSource`, decoders and presenters in CmuxNextRemoteView; spec-coverage.md:665 lists "Remote Chromium tab view" as NO OWNER; this proposal takes it.
