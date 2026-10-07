# A2 `ghostty`: the iOS terminal renderer

Status: lane A2 of plans/cmux-next/ios-next/PLAN.md, 2026-10-06. Branch
`feat-cmux-next-ios-a2-ghostty`. Binding: ghostty-next.md (sections 2 to 9,
D1 to D9), ios-rewrite.md section 10.6, ios-keyboard.md (KB1 to KB4),
architecture.md. Consumers: C1 `terminal-rpc` (cmux session host), C9 `ssh`,
D1 `terminal-ux`.

## 1. Audit: what exists

| Need | Exists today | Gap |
| --- | --- | --- |
| Ghostty Metal surface in a UIView | `GhosttyTerminalView` (plain UIView, Ghostty adds its layer, draws on change, coalesced per mailbox tick in `GhosttyNextApp.requestDraw`) | no occlusion on background, no pinch, no font or theme control |
| Manual I/O | `GHOSTTY_SURFACE_IO_MANUAL_MIRROR` only | SSH has no host parser: it needs `GHOSTTY_SURFACE_IO_MANUAL` (Ghostty answers DA/DSR/CPR) and a phone-owned grid |
| Byte/snapshot source | `TerminalSessionSource` (attach by `TerminalRef`, events carry encoded `terminal_bytes` frames, presence, input, snapshot request); `TerminalViewController+Stream` binds it | shaped for the cmux host only: listing, refs, frames. SSH would have to fake GHOSTSNP frames. The binding lives in a view controller, so C1/D1 cannot reuse it in their own screens |
| GHOSTSNP restore on attach, resize, overflow, digest | `CmuxTerminalStream.TerminalViewer` + `TerminalStreamPipeline` (one serial output queue, READY deadline, throttle retry, digest compare, generation drop) | complete; keep |
| Key encoder input | `TerminalInputRouter`, `GhosttyTerminalView+Keys/+TextInput/+Input` (pressesBegan to `ghostty_surface_key` with HID usages, `UITextInput`, preedit, key bar, sticky modifiers) and tests | complete; keep |
| Selection and copy | none | Ghostty has mouse selection, `read_selection`, `copy_selection_to_clipboard_bounded`, `select_viewport_cell` |
| Links | `action_cb` returns false for everything | route `OPEN_URL` and `SET_TITLE` per surface; tap to open |
| Scrollback budget | `scrollback-limit-bytes = 8 MiB` written to a temp file at app init | no pan to scroll local history; config built ad hoc |
| 120 Hz | `CADisableMinimumFrameDurationOnPhone` is in Info.plist; frames are on demand | nothing asks for 120 Hz during gestures; no thermal/Low Power cap |
| Dynamic Type | fixed `font_size = 13` | none |
| Theme | Ghostty default colors | none; `Packages/Shared/CmuxTheme` (`ThemeInput`, `ThemeTokens`) is the cmux token source |
| Fixture benchmark | `schemas/terminal-corpus` (7 cases, host snapshot hashes) used by `crosscheck/` | no flood or htop-style case, no on-device replay, no frame timing |
| Tests | router, real-surface key bytes, viewer (CmuxTerminalStream) | pure renderer policy has no home that runs without a simulator |

## 2. Plan

### 2.1 The source protocol (what C1 and C9 implement)

New platform-neutral package `Packages/Shared/CmuxTerminalRenderCore` (no
UIKit, no Ghostty), so a carrier or the SSH package implements it without
linking the renderer:

```swift
public protocol TerminalByteSource: AnyObject, Sendable {
    var authority: TerminalAuthority { get }      // .host (mirror) or .local (phone owns parser and grid)
    func open(_ viewport: TerminalViewport) async throws -> AsyncStream<TerminalSourceEvent>
    func send(_ input: Data) async throws         // ordered, attributed; never queued offline
    func viewportChanged(_ viewport: TerminalViewport) async  // presence: visible + cols x rows
    func requestSnapshot(_ request: SnapshotRequest) async throws  // .host only
    func close() async
}
public enum TerminalSourceEvent: Sendable {
    case frame(TerminalFrame)       // .host: terminal-snapshot-v1 frame (bytes, READY, HISTORY, digest)
    case bytes(Data)                // .local: raw PTY output (SSH channel data)
    case grid(cols: Int, rows: Int, generation: UInt32)   // .host only
    case snapshotThrottled(retryAfterMilliseconds: Int, requestID: String)
    case title(String)
    case path(TerminalPath, rttMilliseconds: Double?)
    case closed(reason: String)
}
```

- `.host` authority (C1, cmux session host): surface in MANUAL_MIRROR, the
  grid comes from `.grid` events, bytes go through `TerminalViewer`
  (snapshot first, gap or digest mismatch resyncs).
- `.local` authority (C9 SSH, fixture replay): surface in MANUAL, Ghostty
  answers terminal queries through `io_write_cb` (they reach `send`), the grid
  follows the view, and `viewportChanged` is the SSH window-change.
- `CmuxiOSTerminal.SessionTerminalByteSource` adapts today's
  `TerminalSessionSource` + `TerminalRef`, so the mock host and the existing
  screen keep working unchanged.

### 2.2 Renderer module

`CmuxiOSTerminal` keeps `GhosttyTerminalView` and adds:

- `TerminalSession` (`@MainActor`): binds one `TerminalByteSource` to one
  `GhosttyTerminalView` (the logic moved out of `TerminalViewController`), so
  C1/D1 embed the view and the session in any screen. The view controller
  becomes a thin client.
- Surface mode chosen from authority. Visibility: `set_occlusion(false)` on
  `sceneDidEnterBackground` and when off window; viewport reported as
  invisible (ghostty-next section 6 rule 1).
- Selection: long-press selects the word (Ghostty double-click semantics),
  drag extends; edit menu Copy / Select All / Paste / Open Link. Copy reads
  `ghostty_surface_read_selection` into `UIPasteboard` (bounded).
- Links: `action_cb` routes `OPEN_URL`, `SET_TITLE` and `MOUSE_OVER_LINK` to
  the owning view through a surface registry; a tap on a link (super-click to
  Ghostty) opens it after `TerminalLinkPolicy` allows the scheme.
- Scroll: one-finger pan scrolls local history (`mouse_scroll`, precision) or,
  with mouse tracking captured, sends wheel events. Local history is capped by
  `scrollback-limit-bytes` (8 MiB, `TerminalGhosttyConfig`).
- 120 Hz: a `CADisplayLink` exists only while a pan or pinch is active; its
  range comes from `TerminalFramePacing` (120 during gestures, 30 under
  serious thermal state or Low Power Mode). Output frames stay on demand.
- Dynamic Type: font size = `TerminalFontSizing` of the body text style's
  scale times the base size, plus the pinch zoom (view state), applied with
  the `set_font_size` binding action. Never changes a host-locked grid.
- Theme: `TerminalGhosttyConfig` renders `ThemeInput` (CmuxTheme tokens) as
  Ghostty config (`background`, `foreground`, `palette`, `selection-*`,
  `cursor-color`) and applies it with `ghostty_surface_update_config`.

### 2.3 Benchmark DEV screen

`TerminalBenchViewController` replays a `TerminalWorkload` through a
`FixtureByteSource` (`.local` authority) paced one chunk per vsync:
corpus cases (bundled copies of `schemas/terminal-corpus`, drift-checked by a
test), plus generated `flood`, `htop` (full-screen cursor-addressed redraws)
and `vim` (scroll-region redraws). Every draw is an `os_signpost` interval
(`cmux.terminal`, `frame`); `FrameTimingStats` reports p50/p95/p99 frame
interval, hitches over the 8.3 ms / 16.7 ms budget and bytes/s on screen and in
`terminal-bench.json` (DEBUG). Entry points: DEV menu, and
`CMUX_IOS_TERMINAL_BENCH=<workload>` for fleet screenshots.

### 2.4 Tests

Swift Testing in `CmuxTerminalRenderCore` (runs with `swift test` on macOS):
workload determinism and shape, frame stats, pacing, font sizing, config
rendering, link policy, cell geometry, scroll accumulator, fixture drift.
Renderer integration stays in `CmuxiOSTerminalTests` (fleet or CI only).

## 3. Not in this lane

Local echo prediction and latency telemetry (C1), terminal list and attach
UI (D1), SSH transport (C9), search UI, Kitty image replay wiring (the
pipeline passes READY only, as ios-rewrite.md 10.6 says).

## 4. Status (2026-10-06)

Done: render core package with 39 Swift Testing tests (`swift test` in
`Packages/Shared/CmuxTerminalRenderCore`, green); renderer session, gestures,
theme, font sizing, link routing, benchmark screen; `CmuxiOSApp`,
`CmuxiOSTerminal` and `CmuxiOSTerminalTests` compile for the iOS simulator
with SwiftPM. New renderer integration tests (DA1 answered by a `.local`
surface and dropped by a `.host` mirror, raw bytes through a `.local`
session, adapter mapping) wait for a fleet or CI run.

Unverified on a device or simulator: gesture feel, 120 Hz during scroll,
link tap, edit menu, benchmark numbers. Blocked: the tagged build `nxa2`
(this host has no `~/.config/macfleet/hosts.json`, so `reload-cloud-ios.sh`
finds no slot; `cmux-ci build ios` needs a pushed ref and GitHub auth here is
broken). To build once pushed: `ios/scripts/reload-cloud.sh --tag nxa2`, then
`CMUX_IOS_HOME_PREVIEW=1 CMUX_IOS_TERMINAL_BENCH=htop` on the simulator for
the benchmark screenshot (`terminal-bench.json` lands in the app caches).
