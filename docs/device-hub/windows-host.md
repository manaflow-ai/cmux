# A Windows PC as a Screen Sharing host

Status: a Windows PC registers, lists, captures and serves viewing sessions (`cmux-rd windows-host`).
Viewing needs the hub to accept `windows` hosts and the Mac to list them (the companion
change on lane/screen-share-windows-hub).

## What runs where today

| | register with the hub | listed on the Mac | capture | input | serves a hub session |
|---|---|---|---|---|---|
| Mac | the app (`MacScreenDeviceHub`) | yes | ScreenCaptureKit | CGEvent | yes (`cmux-rd serve`, driven by the app) |
| Linux | `cmux-rd linux-host enable` | yes (`DevicePlatform.linux`, #43537) | X11 XShm + XDamage; Wayland via the ScreenCast portal (view only) | XTest | yes (`linux-host run` drives `cmux-rd serve`) |
| Windows | `cmux-rd windows-host enable` | as a Windows device (platform `windows`) | GDI BitBlt (`windows.rs`), DXGI Desktop Duplication probed | SendInput (`windows.rs`) | yes (`windows-host run` drives `cmux-rd serve`, step 4) |

`cmux-rd host` on Windows already streams cmux.rd/1 over a TCP stream (the
`cmux-rd-windows.yml` live proof: a Mac viewer decodes the Windows desktop over the tailnet).
What Windows lacks is the device hub path: the secure link and the session loop around it.

## 1. Register as `windows`

`cmux-rd windows-host` shares the hub client of `linux-host` (the cmux-hub-host crate): a P-256
device key, Stack sign-in once at `enable`, `POST /v1/devices` with `platform: "windows"`,
an anchor so the PC renews its own host session for 30 days with its device key, and the
User DO socket held by `windows-host run` (online while it runs). The hub accepts `windows`
as a host platform next to `macos` and `linux`; the Mac decodes `DevicePlatform.windows` and
labels the row "Windows".

Files: `%APPDATA%\cmux\screen-host\` (device.json, account.json, consent.json) and
`%LOCALAPPDATA%\cmux\screen-host\run\` (capture.json, pending requests). The profile's
inherited ACL gives only the user, SYSTEM and Administrators access; reads refuse a symlink
or junction in place of a file. Keep it running at logon:

    schtasks /Create /SC ONLOGON /TN cmux-screen-host /TR "C:\path\cmux-rd.exe windows-host run"

It must run in the interactive user's session: a service in session 0 cannot capture the
desktop or inject input into it.

`enable` turns sharing on and downloads Cisco's OpenH264 into `%LOCALAPPDATA%` (the
encoder; never bundled). `run` serves each approved session (step 4).

## 2. Capture

- Now: GDI BitBlt from the screen DC (`GdiCapture`), top-down BGRA into
  `cmux_encode::bgrx_rect_to_i420`. Works on every runner, no GPU needed; full-frame reads,
  no damage, so the session loop paces it by timer (the frame gate drops unchanged frames).
- Next: Windows.Graphics.Capture (`windows` crate, `GraphicsCaptureItem` for a monitor) for
  per-monitor capture with a dirty-region hint and the cursor composited, or DXGI Desktop
  Duplication (`IDXGIOutputDuplication::AcquireNextFrame`, already probed by
  `dxgi_desktop_duplication_probe`) whose dirty and move rects map straight onto the
  engine's damage `Rect`s. Desktop Duplication first: it gives damage, needs no WinRT
  apartment and runs on Windows 8+; WGC when per-window capture is wanted.

## 3. Input and encode

- Input: `SendInput` (pointer absolute over the virtual desktop, buttons, wheel, scancodes
  from HID usages, Unicode text): already in `windows.rs` (`apply_input`).
- Encode: the same path as every host: Cisco's OpenH264 (downloaded and pinned, `cmux-rd
  openh264-install`) through `encoder::H264Encoder`; Media Foundation hardware H.264 is
  probed (`media_foundation_probe`) for a later encoder. The engine (`cmux-rd-engine`:
  frame gate, congestion control, FEC, NACK, exactly-once input) is shared unchanged.

## 4. Serve a hub session

1. `cmux-rd-link`'s `net` driver runs on Windows (`net_windows.rs`): each wake-up is a pair
   of loopback UDP sockets connected to each other, the driver waits on its socket and its
   command wake-up with `WSAPoll`, the buffers grow through Winsock's `setsockopt`, and the
   host candidates are the source addresses the routing table picks for the default route,
   the tailnet and the private ranges (no `getifaddrs`). `Net::wait` blocks on the event
   wake-up on every OS; `event_socket()` gives it to a caller's own `WSAPoll`.
2. `cmux-rd serve` on Windows (`windows_serve.rs`) speaks the Unix `serve`'s JSON lines. A
   thread reads stdin; the loop waits on the link until the next frame (20 ms at most, for the
   app's lines). The media is `cmux-rd host`'s Windows session (`windows/session.rs`: GDI,
   OpenH264, the shared engine, SendInput) over the link instead of a TCP stream. A `view`
   session gives the engine no input gate and injects nothing.
3. `windows-host run` drives `serve` per approved ticket with the session code it shares with
   linux-host in cmux-hub-host: `session.rs` (signaling, the signed answer, candidates both ways),
   `rd_doc.rs`; and in `src/screen_host/`, `serving.rs` (the hub socket's pushes, consent read every second, one
   session at a time, a session stopped when the hub link drops) and `requests.rs`
   (`requests|approve|deny`).
4. CI: `cmux-rd-windows.yml` runs the link's real-UDP session test on the Windows runner and
   `cmux-rd windows-serve-selftest` (a `serve` child played by a viewer on the runner, view and
   control: media arrives, the stop ends it), and uploads the installable `cmux-rd.exe`
   (features `link,openh264`).

The mouse pointer is drawn into each frame (`GetCursorInfo` and `DrawIconEx` after the
`BitBlt`, which leaves it out). Not yet: one capture spans the whole screen (no display
picker), and `max_width` is not applied.

## Consent

The same model as the Mac and Linux: the hub admits only a viewer the person allowed;
`ask` requests wait for the person. The per-machine control/screen switches live in the
acpmux consent store (`_acpmux/machine_consent_get`, `~/.acpmux/machine-consent/consent.json`,
owned by the remote-control consent lane); when acpmux runs on the PC, `windows-host run` reads
the effective `screen`/`control` values from that store instead of its own consent.json, the
way linux-host will. Until then it keeps the linux-host consent.json (view only by default).

## What does not work on Windows, by design of the OS

- UAC prompts and anything else on the secure desktop (Winlogon): a user-session process
  cannot capture or inject into it. The viewer sees the last frame (or a uniform frame) until
  the prompt is answered at the PC. Capturing it needs a SYSTEM service plus a per-session
  helper with `uiAccess`, signed: out of scope.
- The lock screen and Ctrl+Alt+Del: same secure desktop; SendInput cannot send the secure
  attention sequence.
- A disconnected session (after RDP disconnects, or fast user switching): no visible
  desktop to capture; `windows-host status` reports a one-color frame.
- Elevated windows: UIPI drops SendInput into a window of a higher integrity level unless
  the host runs elevated (not recommended) or with `uiAccess`.

No other permission is needed: Windows has no Screen Recording or Accessibility grant.
