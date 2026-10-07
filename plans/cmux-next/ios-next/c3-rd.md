# C3 `rd`: remote desktop on the phone

Status: lane C3 of [PLAN.md](PLAN.md), 2026-10-06, branch `feat-cmux-next-ios-c3-rd`, based on
`feat-cmux-next-ios` plus the unmerged C2 branch `feat-cmux-next-ios-c2-browser` at `0b82c70` (merged in,
because C3 rides C2's `cmux.rd/1` Swift wire, datagram lanes and VideoToolbox encoder).
Wire: [a0-rpc.md](a0-rpc.md) 3.4 and 5.5. Link: [a3-link.md](a3-link.md). Host seam: [b5-mac-host.md](b5-mac-host.md)
(`MobileChannelHandler`, `MobileSessionGate`, relay rules). Video path: [c2-browser-stream.md](c2-browser-stream.md).
Engine and policy: [remote-desktop.md](../remote-desktop.md) (RD1 to RD10, 11 security, 12 RFB).

## 1. What "VNC" means here

The phone views and drives a desktop that the Mac can reach. Two target kinds, one channel kind (`rd`),
one video path, one input vocabulary:

| Target | Source on the Mac | Typical use |
| --- | --- | --- |
| `display` | ScreenCaptureKit display capture of one of this Mac's displays; CGEvent input | "show me my Mac" from the couch, approve a dialog, read a build log on the big screen |
| `window` | ScreenCaptureKit capture of one window; input in that window's coordinates | follow one app (a simulator window, a browser) at full sharpness |
| `vnc` | the Mac runs an RFB 3.8 client to a server it can reach (a Cloud VM's VNC server, a Linux box on the LAN or tailnet, another Mac with Screen Sharing in VNC-password mode) and re-encodes its framebuffer | reach machines that run no cmux, through the Mac the phone already trusts |

The phone never speaks RFB and never opens a socket to the target: RD9 (RFB as a client only) holds,
and the Mac is the only place that holds RFB state. The Mac proxies RFB semantics, never raw bytes: it
refuses a peer whose first 12 bytes are not an RFB `ProtocolVersion`, and the phone cannot send bytes
that reach the target except as pointer, key and clipboard events the Mac encodes itself.

The headless Rust engine (`cmux-rd-host`, Linux X11) is not on this path. A Mac host in phase 2 of
remote-desktop.md runs in the screen agent helper; until that helper exists, the cmux-next app process
(which already terminates the phone's link, b5-mac-host.md 1) captures and injects, behind protocols
that the helper can implement later without a wire change.

## 2. Transport

Decision: **H.264 from VideoToolbox as `cmux.rd/1` video datagrams on the C2 datagram lane, rd stream
framing on the reliable `rd` channel when the path has no unreliable lane.** Same as C2, for the same
reasons (c2-browser-stream.md 1): carrier independence (V3 direct and the DO relay have no WebRTC
tracks), one media pipeline for browser, desktop, simulator and remote tabs, damage-driven frames with
`ref_frame` recovery, and no playout jitter buffer. A WebRTC video track (b2-webrtc.md) is not used; the
`rd:opened` schema keeps `webrtc_track` as a reserved alternative for D2 if rd misses its budget on a
path where a track exists.

Channel: `rd` (interactive, reliable, `input` priority) plus an optional datagram lane
`cmux.mobile/datagram/<id>` (unreliable unordered, `media` priority), bound by name exactly like C2's.
Record payloads are rd stream frames without the length (A0 3.4): type 1 control JSON, type 2 one rd
datagram. Phone to Mac input is native rd `InputEvent`s (HID key usages, absolute pointer, buttons,
precise scroll, committed text), not `rb/1` service events: the desktop service is rd's own.

The rd `hello`/`welcome`/`start` handshake is replaced by `channel.open`/`channel.opened`; rd's token
claims are not used on the link because B5's hello proof already authenticated the device.

### 2.1 `channel.open` params (`rd.schema.json`)

```
{ service: "desktop",
  target: {kind: "display", display?: <id>} | {kind: "window", window: <id>}
        | {kind: "vnc", host: <hostname or IP>, port?: 5900, name?: <label>},
  mode: "view" | "control",
  screen: {pixel_width, pixel_height, scale},   // the phone viewport in backing pixels
  codecs?: ["h264"], datagram_lane?: true }
```

`display` (integer) at the top level stays accepted as the A0 0.x shorthand for `target.kind = display`.

### 2.2 `channel.opened` params

```
{ media: "rd_datagrams", datagram_channel, encoder: "h264",
  target: {kind, width, height, scale, name},   // full target size in target pixels
  view: {x, y, width, height, pixel_width, pixel_height, seq: 0},  // what the video shows
  displays: [{id, name, width, height, scale, main}],  // display targets only
  mode: "view" | "control", cursor: "local" | "in_video",
  caps: ["clipboard", "displays", "windows", "view"] }
```

### 2.3 Desktop control messages (`desktop/1`, rd `{t: "service", service: "desktop/1", body}`)

Shared vectors: `schemas/remote-desktop/desktop.json`, replayed by Swift (`CmuxRemoteDesktopTests`) and
Rust (`cmux-rd-proto` feature `serde`, module `desktop`).

| Direction | `t` | Meaning |
| --- | --- | --- |
| phone to Mac | `desktop.view {seq, x, y, width, height, pixel_width, pixel_height}` | show this target rect at this encode size (zoom and pan end, rotation) |
| Mac to phone | `desktop.view_applied {seq, x, y, width, height, pixel_width, pixel_height}` | clamped answer; the next frame is a keyframe of that region |
| phone to Mac | `desktop.select {display}` | switch display (display targets) |
| phone to Mac | `desktop.windows.list` / Mac `desktop.windows {windows: [{id, app, title}]}` | window picker |
| phone to Mac | `desktop.mode {mode}` / Mac `desktop.mode_applied {mode, reason?}` | view/control toggle; control needs Accessibility and consent |
| phone to Mac | `desktop.clipboard.push {seq, text}` | right before a paste the user started |
| phone to Mac | `desktop.clipboard.pull {seq}` / Mac `desktop.clipboard {seq?, text}` | explicit "copy from Mac"; VNC `ServerCutText` arrives unsolicited |
| phone to Mac | `desktop.auth {password}` | VNC password, only after `desktop.state auth_required` |
| Mac to phone | `desktop.state {state, reason?}` | `waiting_consent`, `auth_required`, `live`, `paused` |
| Mac to phone | `desktop.ended {reason}` | `stopped_by_host`, `consent_denied`, `permission_revoked`, `target_gone`, `vnc_closed` (then `channel.closed`) |

## 3. Input

Pointer coordinates are target pixels of the full target (independent of the encode size and of the
view crop), so input never depends on which frame the phone is showing.

| Phone gesture (trackpad mode, default) | rd events |
| --- | --- |
| one-finger drag | moves a local cursor by the finger delta times an acceleration curve; `pointer` once per display frame |
| tap | `button 1 down/up` at the cursor (rd buttons use X numbering: 1 primary, 2 middle, 3 secondary) |
| two-finger tap | `button 3 down/up` (secondary click) |
| hold, then drag | `button 1 down`, moves, `button 1 up` on lift (drag and select) |
| two-finger pan | `scroll` precise, in hundredths of a point, positive down, natural direction |
| pinch | local zoom around the fingers; at gesture end `desktop.view` for the visible rect so the Mac re-encodes it sharp |
| three-finger tap or toolbar | show or hide the keyboard |

Direct mode (toolbar switch): the cursor jumps to the finger (`pointer` at the touch point, then
`button 1`), drags move it, long press is a secondary click. iPad pointer and hardware keyboard work in
both modes (pointer `move`, `UIPress` HID usages with modifiers).

Keyboard: software keyboard text as `text` events (committed IME text included; marked text stays on
the phone until committed). Backspace, return, tab, escape, arrows and function keys as HID `key`
events. A modifier bar above the keyboard (control, option, command, shift latch; esc, tab, arrows) sends
modifier key down before the next key and up after it, or stays held while latched. Hardware keys go
out as HID usages (page 7) with their modifier usages. The Mac maps usages to CGKeyCodes (display and
window) or to X11 keysyms (VNC, `HidKeysymMap`).

## 4. Scaling, zoom and pan

- The first view is the whole target fit into the phone viewport: encode size = target size scaled to
  fit `screen.pixel_width x pixel_height`, capped at the target's own pixels and 2560 on the long edge,
  even. A 3024x1964 Retina display on a 1179x2556 portrait iPhone encodes at 1178x764.
- Pinch zooms the current frame locally at once (no round trip). At gesture end the phone sends
  `desktop.view` with the visible target rect and the viewport's pixel size; the Mac crops there
  (`SCStreamConfiguration.sourceRect` for displays and windows, a framebuffer crop for VNC), answers
  `desktop.view_applied`, and the next keyframe is that rect at full sharpness. Until then the phone
  keeps scaling the previous frame, mapped through the view it was encoded for.
- While zoomed the lens follows the trackpad cursor when it nears an edge, and pinching moves it around
  the fingers; when the gesture ends the same `desktop.view` goes out. (Two fingers scroll the remote
  content, so there is no separate lens pan.)
- One pure type, `RemoteDesktopViewport` (phone, CmuxiOSRemoteDesktopCore), owns the math: view rect in
  target pixels, zoom, lens offset, screen point to target point, target rect for a frame encoded for
  another view. Tested without UIKit.

## 5. Clipboard

No mirroring and no polling. Phone to Mac: `desktop.clipboard.push` right before a paste the user starts
(the Paste key on the modifier bar sends push, then Cmd-V or, for VNC, Ctrl-V as chosen by the target
kind). Mac to phone: only on `desktop.clipboard.pull` (the "Copy from Mac" toolbar item), so the Mac reads
its pasteboard only on an explicit request, and VNC `ServerCutText` while the screen is visible. Policy:
clipboard on for own-account devices (the only devices B5 admits today), every transfer counted, never
logged with content.

## 6. Multi-display

`channel.opened.displays` lists the Mac's displays (id, name, pixels, scale, main). The toolbar shows a
display picker when there is more than one; `desktop.select` reconfigures the capture to that display
(new view at fit, keyframe). Windows: `desktop.windows.list` returns on-screen normal windows of the
console user (title, app); picking one reopens the channel with `target.kind = window`. Titles go only
to the owner's own devices (remote-desktop.md 11.1).

## 7. Permissions on the Mac

`RemoteDesktopPermissions` reports Screen Recording (`CGPreflightScreenCaptureAccess`) and Accessibility
(`AXIsProcessTrusted`). Display and window targets need Screen Recording: without it the channel is
refused `rd.permission_denied` with `details {permission: "screen_recording"}`, and the phone shows
"Allow Screen Recording for cmux on your Mac" with no retry loop. The Mac never raises the TCC prompt
from a phone request (a prompt nobody sees is a hang); the app's Settings owns that. Control needs
Accessibility: without it the session runs in view mode, `channel.opened.mode` is `view`, and
`desktop.mode` answers `mode_applied {mode: view, reason: accessibility}`. VNC targets need neither.
A permission revoked mid-session (ScreenCaptureKit stops the stream) ends it with
`desktop.ended {reason: permission_revoked}`.

## 8. Security

- Paired devices only. The `rd` channel exists only inside a B5 session admitted by a device proof
  (paired, unrevoked, same account). Input, mode changes, clipboard and VNC auth act only while
  `gate.isOpen`; revocation closes the gate before the channel, so no event reaches CGEvent or RFB after.
- Consent per session. Every session asks `RemoteDesktopConsent` on the Mac before the first frame
  (`desktop.state waiting_consent` meanwhile): the app shows a floating panel at the top center of the
  active screen with the device name, target and mode, Allow and Deny, no default button (D-RD7), deny
  after 30 s on the injected clock. Control is a second consent when the phone switches from view.
  Policy `RemoteDesktopConsentPolicy.ask` is the default; `.indicatorOnly` (the owner opted out of the
  prompt for their own devices) is a Mac setting, never a phone param.
- Indicator. While any session lives, `RemoteDesktopIndicator` shows the menu bar item and the screen
  pill "Viewed by <device>" / "Controlled by <device>" with Stop. Stop ends that session at once
  (`desktop.ended stopped_by_host`); Stop All ends every session. No frame and no input after Stop.
- Input containment: input injection only in control mode, only while the gate is open and the consent
  stands. Window targets clamp pointer events to the window's frame. Agents never get this channel
  (B5 admits devices, not agents; RD8).
- VNC proxy: the phone names a host and port (default 5900). This is no new capability for an
  own-account device that can already type into the Mac's terminals, but the Mac still limits it: only
  hostnames or IP literals (no URLs, no user info), ports 1 to 65535 except the Mac's own loopback
  service ports when `RemoteDesktopVncPolicy.allowLoopback` is false (default: loopback allowed, so a
  local VM or simulator VNC works), RFB handshake required within 10 s, security types None and VNC
  authentication only (Apple's type 30 and others refused `rd.vnc_auth_unsupported`). The password
  travels once inside the encrypted link, is used for the DES challenge and dropped; it is never stored,
  logged or echoed. Policy `.off` disables VNC targets entirely.

Relay analysis (skills/cmux-socket-policy): control-mode input is code execution on the Mac by design
(execute risk), allowed only to the owner's paired devices with live consent and the indicator. View
mode executes nothing. No `rd` param carries a command, path or URL; `target.display` and
`target.window` must resolve in the Mac's current lists; `vnc.host` is validated as above.

## 9. Code

| Piece | Where |
| --- | --- |
| `desktop/1` messages, `rd` channel params and opened, view math shared by both ends, HID usage to keysym map, phone client (`RemoteDesktopClient` over a `MobileChannel` and its datagram lane) | `Packages/Shared/CmuxRemoteDesktop` (module `CmuxRemoteDesktop`, on `CmuxBrowserStream` for the rd wire) |
| phone datagram lane open | `MobileLinkClient.openDatagramLane(pairedWith:)` (CmuxMobileLink) |
| Mac handler | `CmuxMobileHost/RemoteDesktop`: `RemoteDesktopChannelHandler` (`MobileChannelHandler` for `.rd`), `RemoteDesktopSession`, seams `RemoteDesktopSources` (targets), `RemoteDesktopTargetSource` (video + input + clipboard), `RemoteDesktopPermissions`, `RemoteDesktopConsent`, `RemoteDesktopIndicator`, policies |
| Mac sources | `DisplayFrameCapture` (ScreenCaptureKit display), `CGEventDesktopInput`, `ScreenDesktopSources`; VNC: `RfbClient` (3.8, Raw, CopyRect, DesktopSize, None and VNC auth), `RfbFramebuffer`, `RfbDesktopSource`, `NWRfbTransport` |
| Video | C2's `CapturedVideoSource`, `VideoToolboxH264Encoder`, `RdPacketizer`, `RdReassembler` (shared; names stay `Browser*` until C2 lands, then move to a neutral `MobileVideo*` in one rename) |
| iOS logic | `ios/CmuxiOS/Sources/CmuxiOSRemoteDesktopCore`: `RemoteDesktopViewport`, `TrackpadPointer`, `RemoteDesktopGestureMapper`, `ModifierLatch`, `LinkRemoteDesktopSource` |
| iOS screen | `ios/CmuxiOS/Sources/CmuxiOSRemoteDesktop`: `RemoteDesktopViewController` (video, gestures, toolbar, keyboard, modifier bar, display picker, VNC connect form), `H264VideoDisplayView` (VideoToolbox decode to `AVSampleBufferDisplayLayer`, newest wins), `RemoteDesktopKeyInputView` (UIKeyInput) |
| Entry | Hosts: a paired Mac's row gets "Remote Desktop" (display) and "Connect to VNC Server" through `RemoteDesktopEntry`; the workspace detail of a Mac gets the same entry in its toolbar menu |

Shared with C2, factored here because C2's iOS screen is not committed yet: `H264VideoDisplayView`
(decode and present) and the rd channel client core. C2 should adopt both when it lands its screen; the
note is in the coordination file. Server side, `RemoteDesktopSession` keeps its own copy of the video
pump and lane switch that `BrowserChannelSession` has (about 80 lines); a shared `RdMediaSender` is the
follow-up once C2 merges, to avoid editing C2's in-flight file now.

## 10. Tests

Swift Testing:
- `CmuxRemoteDesktopTests`: `desktop.json` vectors decode and re-encode; channel params and opened
  round trip and validation (bad target, VNC host with a scheme, port 0); view clamp and fit math; HID to
  keysym table; client against a scripted host over loopback (open, view request, input sequence,
  refusal).
- `CmuxMobileHostTests/RemoteDesktop*` over `CmuxLinkTesting` loopback with `MobileHost`, a fake target
  source, fake permissions, fake consent and indicator: frames flow after consent, consent denied ends
  before any frame, permission missing refuses `rd.permission_denied`, no Accessibility forces view,
  input injected only in control mode and only while the gate is open (revocation test), Stop from the
  indicator ends the session and no frame follows, view request applied and clamped, display switch,
  clipboard push and pull, datagram lane carries video.
- `RfbClientTests`: against an in-process scripted RFB server over a pipe transport: version and
  security negotiation, VNC auth DES response against a known vector, Raw and CopyRect updates into the
  framebuffer, DesktopSize resize, pointer and key event encoding, ServerCutText, refusal of a non-RFB
  peer and of unsupported security types.
- `CmuxiOSRemoteDesktopCoreTests` (macOS runnable): viewport mapping, trackpad acceleration and clamp,
  gesture mapping to rd events, modifier latch.

Rust (written, not run locally): `cmux-rd-proto/tests/desktop.rs` replays `schemas/remote-desktop/desktop.json`
through `desktop::DesktopMessage` (feature `serde`).

Status 2026-10-07: `CmuxRemoteDesktopTests` 24 pass; `CmuxMobileHostTests` 82 pass (13 remote desktop
channel tests and 10 RFB tests new, the 59 earlier ones unchanged); `CmuxMobileWireTests` pass with the
new rd errors and fixtures; `CmuxiOSRemoteDesktopCoreTests` 9 pass on macOS through a scratch package
(the CmuxiOS package itself only builds for iOS) and compile for the simulator; `CmuxiOSApp` compiles
for `arm64-apple-ios17.0-simulator`. The VNC DES response is checked against a vector computed with
LibreSSL. The Rust test is formatted with rustfmt and not run.

## 11. Live verification needed (tagged Mac+iOS pair)

ScreenCaptureKit display capture and CGEvent injection from the cmux-next app with real TCC grants;
consent panel and indicator UI (app wiring, below); VNC to a Cloud VM guest's VNC port and to a Linux
`x11vnc`; gesture feel; latency (tap to photon) for D2; multi-display switch on a Mac with two displays.

App wiring left to the app lane (no local app build, disk): register
`RemoteDesktopChannelHandler(sources: ScreenDesktopSources(...), consent: <panel>, indicator: <menu bar>)`
in `MobileHost(handlers:)`; the consent panel and indicator are AppKit in `CmuxNextMobile`.

## 12. Follow-ups

ZRLE and Tight decoding for VNC (Raw is fine on a LAN, heavy on WAN); Apple's RFB security type 30 for
Screen Sharing without a VNC password; cursor shape channel (RD6) instead of the local arrow; FEC and
GCC through an iOS slice of `cmux-rd-ffi` (shared with C2); HEVC; audio; the screen agent helper as the
capture and input owner (remote-desktop.md RD10); `RdMediaSender` shared with C2.
