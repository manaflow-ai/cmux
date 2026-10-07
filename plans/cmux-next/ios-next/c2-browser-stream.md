# C2 `browser-stream`: Mac browser surfaces on the phone

Status: landed on branch `feat-cmux-next-ios-c2-browser` (lane C2 of [PLAN.md](PLAN.md)), 2026-10-06.
Wire: [a0-rpc.md](a0-rpc.md) 3.4 and 5.4. Link: [a3-link.md](a3-link.md). Host: [b5-mac-host.md](b5-mac-host.md)
(`MobileChannelHandler`, `MobileSessionGate`). Shell seam: [a1-shell.md](a1-shell.md) 2.3. Protocol it reuses:
`cmux.rd/1` (`cmux-rd-proto`) and `cmux.rb/1` (`cmux-remote-browser`, `schemas/remote-tab/`), remote-tab.md RT4 to RT6.

The phone shows a browser tab that runs in the Mac app (CEF or WebKit). Pixels are encoded on the Mac;
the phone decodes, draws, and sends input and navigation back. The tab record (url, title) belongs to
the workspace store; the page runtime belongs to the Mac app; the phone holds view state only (zoom
lens, pan, URL field draft).

## 1. Video path decision

Decision: **H.264 from VideoToolbox, carried as `cmux.rd/1` video datagrams on an unreliable CmuxLink
lane paired with the browser channel; rd stream-carrier framing on the reliable browser channel when
the path has no unreliable lane.** No WebRTC media track. HEVC is used when the phone lists `hevc` and
the Mac has a hardware HEVC encoder (cap negotiated in `channel.open`); this lane ships H.264 only.

Why, without measurements:

- Carrier independence. A WebRTC track exists only on B2/B3. The preferred path is V3 direct (no
  WebRTC at all) and the DO relay has no media. rd datagrams ride any carrier with an unreliable lane
  and degrade to the reliable stream mode everywhere else, behind the same handler.
- One media pipeline. C3 (remote desktop), C14 (simulator streaming) and remote tabs (remote-tab.md
  RT6: "No WebRTC, no QUIC") already use `cmux.rd/1`. A0 already carries `cmux.rb/1` unchanged inside
  the browser channel; putting video next to it keeps one decoder, one recovery model, one bench.
- Screen-content control. A WebRTC track owns its encoder pipeline: it expects a fixed cadence, adds
  B-frame-free but jitter-buffered playout, and reacts to congestion by lowering resolution, which
  blurs text first. rd frames are damage-driven (an idle page sends nothing), carry `ref_frame` for
  recovery frames, and leave room for rd's refine and lossless tile top-off (RT4).
- Latency. The phone decodes newest-wins with no jitter buffer; a WebRTC receiver holds at least one
  frame for playout smoothing.
- Cost we take on: congestion control and loss repair are ours. This lane ships a simple AIMD on rd
  feedback and recovery by keyframe; rd-core's GCC-style controller and Reed-Solomon FEC (Rust,
  `cmux-rd-core`) arrive when `cmux-rd-ffi` gets an iOS slice (follow-up, section 11).

What D2 must measure (scoreboard, per path: direct LAN, direct over Tailscale, WebRTC P2P, TURN):
input-to-photon p50 and p95 (marker frame, tap to first changed frame on the phone), at 0, 1, 3 and 5%
loss and 50 and 100 ms added RTT; keyframe rate and frame completion rate; bitrate against text
legibility (PSNR on a static text page after 1 s); phone decode CPU and battery over 10 minutes of
scrolling; time to first frame after `channel.open`. A WebRTC-track prototype on B2 is built only if
rd misses the budget in section 8 by more than one frame on a path where a track is available.

## 2. Wire binding

One browser surface = one A0 `browser` channel (interactive, reliable) plus an optional datagram lane.

`channel.open` params (browser.schema.json, extended here): `tab` (`tab_…`), `service: "rb/1"`,
`screen {css_width, css_height, scale, refresh_hz?}` (the phone viewport, CSS px), new optional
`codecs: ["h264", "hevc"]` and `datagram_lane: true` (the phone will open the lane).

`channel.opened` params: `media: "rd_datagrams"`, `datagram_channel` (the browser channel's own id:
the lane's records carry it), plus `encoder` (`h264`), `width`, `height` (encode pixels),
`page {css_width, css_height}` (the Mac page viewport) and `caps` (`navigate`, `clipboard`).
Refusals: `browser.tab_not_found` (no browser tab with that id in this host's tree),
`validation.invalid` (bad params).

Datagram lane: the phone opens a link channel with reliability `unreliableUnordered`, priority
`media`, stream name `cmux.mobile/datagram/<browser channel id>`. It carries A0 records with the
browser channel's id, its own per-direction seq (gaps are loss) and no `channel.open` (an unreliable
first record could be lost). `MobileSessionServer` hands such a link channel to the open `MobileChannel`
of that id (`MobileChannel.datagramLanes()`), also when it arrives first. The host starts every stream
in stream mode and switches to the lane when it attaches; if the lane closes (path fell back to the
relay) it switches back. The phone accepts video from both, deduplicated by `(frame, index)`.

Record payloads on both: `RdStreamFrame` (A0 3.4). Type 1 = rd control JSON; type 2 = one rd
datagram (16-byte `DatagramHeader` + payload). Directions:

| Direction | Type | Content |
| --- | --- | --- |
| Mac to phone | 1 | rd `{t: "service", service: "rb/1", body: <rb control>}`: `rb.page`, `rb.state`, `rb.cursor`, `rb.text_input`, `rb.clipboard.write`, `rb.screen_applied`, `rb.navigate.result`, `rb.open_tab`, `rb.menu.show`, `rb.dialog.show`, `rb.closed` |
| Mac to phone | 2 | rd `video` datagrams (FrameBody shards, `fec_count` 0), `input_ack` |
| phone to Mac | 1 | rb `rb.navigate`, `rb.history`, `rb.screen`, `rb.visibility`, `rb.clipboard.push`, `rb.menu.result`, `rb.dialog.result`, `rb.close` |
| phone to Mac | 2 | rd `input` packets (rb input events as `service` events, `must_deliver`), rd `feedback` (loss statistics on the lane; a `need_recovery` request always on the reliable channel so it cannot be lost) |

The rd `hello`/`welcome`/`start` handshake is replaced by `channel.open`/`channel.opened`: the device is
already authenticated by B5's hello proof, so rd's token claims are not used on the link.

`rb.navigate {request, url}` and `rb.navigate.result {request, refused?}` are new `cmux.rb/1`
messages (added to `cmux-remote-browser` `proto.rs` and `schemas/remote-tab/messages.json`, cap
`navigate`): the phone has no local omnibar engine, so loading a typed URL is an op on the page owner.
The host refuses every scheme except `http` and `https` (`refused: "scheme"`) and URLs without a host
(`refused: "invalid"`), before the page sees them.

Shard sizes: 1184 bytes of rd payload on the lane (record stays under 1232 bytes), 16 KiB in stream
mode. The last data shard is zero-padded (rd framing), so rd-core's reassembler can replace the Swift
one without a wire change.

## 3. Adaptive bitrate, frame rate and resolution

- Resolution follows the phone, not the Mac. Encode size = the Mac page viewport scaled to the phone's
  backing pixels at fit width (page width fills the phone width), times the zoom bucket (1 or 2, sent in
  `rb.screen` when a pinch ends above 1.5x), capped at the page's own backing pixels and at 2560 px on
  the long edge, rounded to even. A 1440x900 pt page on a 393 pt iPhone at 3x encodes at 1179x737.
- `rb.screen` goes out once per gesture end or rotation (never per frame); the host answers
  `rb.screen_applied {seq, pixel_width, pixel_height}` and the next frame is a keyframe at the new size.
- Frame rate: damage-driven up to `min(refresh_hz, 60)`; an unchanged page sends nothing.
- Bitrate (datagram mode): start 3 Mbps; on each rd `feedback` the host computes loss from arrivals
  and NACKs; `need_recovery` or loss above 2% multiplies the target by 0.7; 1 s without loss adds 10%,
  up to 12 Mbps. Relay paths use remote-desktop's relay caps (15 fps, 4 Mbps).
- Stream mode needs no estimator: the reliable channel's link credit back-pressures the sender; the
  capture slot is newest-wins, so frames that could not be sent are never encoded, and a send that
  waits longer than two frame intervals lowers the target by the same 0.7 step.

## 4. Input

All input is `cmux.rb/1` `InputEvent` JSON inside rd input packets (`service` events, `must_deliver`),
on the reliable browser channel at `input` priority. The link already gives exactly-once in-order
delivery, so rd's repeat-until-acked is redundant here; the host still acks (`input_ack`) so the phone
can show when the Mac applied the last key. The host applies an event only while `gate.isOpen` and
only in sequence order (a seq at or below the last applied is ignored, a jump is refused).

| Phone gesture | rb event |
| --- | --- |
| tap | `pointer down` + `up`, `button` 0, `click_count` from the tap chain (double tap = double click, triple = paragraph), `pointer_type: "touch"` |
| long press | `pointer down`/`up` with `button` 2 (context menu; `rb.menu.show` is answered `cancel` until menus land) |
| one-finger pan | `wheel` precise with `phase` began/changed/ended, then `momentum_phase` from the scroll view's deceleration |
| pinch | local zoom lens (view state, no round trip); at gesture end `rb.screen` with the zoom bucket so the Mac re-encodes sharper |
| two-finger pan while zoomed | local lens pan |
| iPad pointer hover | `pointer move`, coalesced to one per display frame |
| software keyboard text | `ime_commit {text}` |
| marked text (Japanese, Chinese IME) | `ime_set_composition {text, selection}`, then `ime_commit` or `ime_cancel` |
| backspace, return, tab, arrows | `key down`/`up` with DOM `code` and `key` |
| hardware keyboard | `key down`/`up` from `UIPress` (HID usage to DOM code table), modifiers, Cmd shortcuts forwarded |

The keyboard shows when the Mac reports a focused text field (`rb.text_input` with `input_type` other
than `none`) or the user taps the keyboard button, and hides when focus leaves.

## 5. Navigation and tabs

- URL bar: shows `rb.page.url` while not editing; Go sends `rb.navigate`. Text without a scheme gets
  `https://`; anything else that is not http(s) is refused on the phone with the host's wording, and
  the host refuses again regardless.
- Back, forward, reload, stop: `rb.history`, enabled from `rb.page.can_go_back`/`can_go_forward`/`loading`.
- Tab list: the host's browser tab records from `workspace:<host>` (owner: the workspace store),
  through `BrowserTabDirectory`. Switching closes the channel and opens one for the new tab. New tabs
  from the phone need `workspace.tab.create`, which B5 refuses today, so the switcher has no "+".
- Page-initiated tabs (`rb.open_tab`) are answered `refused: "not_supported"` until the phone can
  create tab records.

## 6. Clipboard

No mirroring. Phone to Mac: `rb.clipboard.push {seq, items}` right before a paste the user starts (the
Paste key in the accessory bar or Cmd-V), then the paste keystroke. Mac to phone: `rb.clipboard.write`
from a page copy sets `UIPasteboard.general` (text items only), only while the screen is visible.

## 7. Cursor shape

`rb.cursor` sets the iPad pointer style (`text` = I-beam, `pointer` = link highlight, others = system
default). On iPhone it has no effect.

## 8. Latency budget (tap to photon, LAN direct)

| Stage | Budget |
| --- | --- |
| touch to send (gesture recognizer, no tap delay) | 8 ms |
| link to Mac | 2 ms |
| page input to new frame (CEF/WebKit) | 8-16 ms |
| capture (ScreenCaptureKit, IOSurface) | 1-2 ms |
| encode (VideoToolbox realtime, no reordering) | 3-5 ms |
| link to phone | 2 ms |
| decode (VideoToolbox) | 2-4 ms |
| present (next vsync, AVSampleBufferDisplayLayer display-immediately) | 0-8 ms at 120 Hz |
| total | median under 45 ms, p95 under 70 ms; add RTT on WAN paths |

Scroll stays on the round trip in this lane (pixels come from the Mac). Above 80 ms RTT the screen
shows the path badge (a3-link.md 6); control stays enabled.

## 9. Code

| Piece | Where |
| --- | --- |
| rd and rb wire in Swift (datagram header, FrameBody, feedback, input packets, rb messages, packetizer, reassembler, Annex-B helpers) | `Packages/Shared/CmuxBrowserStream` (module `CmuxBrowserStream`) |
| phone client: channel handshake, datagram lane, reassembly, input seq, navigation requests | same module, `BrowserStreamClient` |
| Mac handler | `Packages/Shared/CmuxMobileHost/Sources/CmuxMobileHost/Browser`: `BrowserChannelHandler` (`MobileChannelHandler` for `.browser`), `BrowserPageHost` / `BrowserPageAttachment` (app seam), `BrowserVideoSource` (pull, newest-wins), `VideoToolboxH264Encoder`, `ScreenCaptureFrameCapture` (macOS) |
| Datagram lane hand-off | `MobileSessionServer` + `MobileChannel.datagramLanes()` |
| iOS screen | `ios/CmuxiOS/Sources/CmuxiOSBrowser`: `BrowserStreamViewController` (URL bar, toolbar, tab switcher), `BrowserVideoView` (VideoToolbox decode into `AVSampleBufferDisplayLayer`), `BrowserGestureMapper`, `BrowserTextInputView` (UITextInput for IME) |
| Real seam | `LinkBrowserStreamSource` (`BrowserStreamSource`) over `MobileSessionLinkProvider` (the admitted link per host; D1/B6 supply it) and `BrowserTabDirectory` |
| Reachability | `SurfaceScreenFactories.browser` (FeatureKit, UIKit only); Workspaces lists a host's browser tabs and opens the screen through it; C5's workspace detail takes the same factory |

App wiring left to the app lane (no local app build, disk): `BrowserPageHost` over the app's browser
tabs (find the tab's view and window, `ScreenCaptureFrameCapture` on that window rect, input through
the CEF shim / WebKit driver input paths, `rb.page` from the tab model) and registering
`BrowserChannelHandler` in `MobileHost(handlers:)`.

## 10. Security

- Input, navigation, history and clipboard act only while `gate.isOpen`; a revoked device's gate
  closes before its channels.
- Navigation refuses non-http(s) schemes (`file`, `javascript`, `data`, `about`, `chrome`, custom app
  schemes) on the host, before the page owner sees the URL.
- The tab id must resolve to a browser tab in this host's workspace tree when the channel opens.
- The phone can never create tabs, run scripts, or read the clipboard of the Mac; a page copy reaches
  the phone only as `rb.clipboard.write` while the stream is visible.

## 11. Tests, verification, follow-ups

Swift Testing, all green on macOS: `CmuxBrowserStreamTests` (22: rd header golden vector and
FrameBody, feedback and input packets matching `cmux-rd-proto`; every rb message in
`schemas/remote-tab/messages.json`; packetizer and reassembler incl. loss, reference chains and
duplicates from both lanes; Annex-B; the client against a scripted host: a missing frame makes the
phone ask for recovery, input seqs, refusal); `CmuxMobileHostTests/BrowserChannelTests` (8, real
`MobileHost` over loopback: frame flow and references, video moving to the datagram lane and a
recovery request bringing a keyframe, 41 input events applied once and in order, scheme refusal for
`file`/`javascript`/`data`/custom, unknown tab, revocation stops input and navigation, resize forces
a keyframe, clipboard both ways; the 45 B5 tests still pass); `CmuxiOSBrowserCoreTests` (10: the real
`LinkBrowserStreamSource` against `MobileHost`, plus lens, tap, scroll-phase, key-map and URL-bar
math). `CmuxiOSApp` and the test targets compile for `arm64-apple-ios17.0-simulator` with SwiftPM.
Rust: `rb.navigate`/`rb.navigate.result` in `proto.rs` with a vectors test, not run locally (no
cargo on this Mac).

Needs live verification (tagged Mac+iOS pair): ScreenCaptureKit capture of a CEF pane, VideoToolbox
encode and decode end to end, gesture feel, IME commit into a page, latency numbers for D2.

Follow-ups: rd-core GCC and FEC through an iOS slice of `cmux-rd-ffi`; context menus and dialogs as
native sheets (`rb.menu.show`, `rb.dialog.show`); capture of tabs that are not on screen on the Mac
(CEF off-screen rendering or WebKit snapshots); refine and lossless tile top-off for static text;
file chooser and downloads over C4.
