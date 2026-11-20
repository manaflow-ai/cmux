# A Windows PC as a Screen Sharing host

Status: a Windows PC registers, lists and captures (`cmux-rd windows-host`, this change).
Viewing it from a Mac waits for the serve port in step 4. This note is the plan; the code
names it where it stops.

## What runs where today

| | register with the hub | listed on the Mac | capture | input | serves a hub session |
|---|---|---|---|---|---|
| Mac | the app (`MacScreenDeviceHub`) | yes | ScreenCaptureKit | CGEvent | yes (`cmux-rd serve`, driven by the app) |
| Linux | `cmux-rd linux-host enable` | yes (`DevicePlatform.linux`, #43537) | X11 XShm + XDamage; Wayland via the ScreenCast portal (view only) | XTest | yes (`linux-host run` drives `cmux-rd serve`) |
| Windows | `cmux-rd windows-host enable` | as a Windows device (platform `windows`) | GDI BitBlt (`windows.rs`), DXGI Desktop Duplication probed | SendInput (`windows.rs`) | no: step 4 |

`cmux-rd host` on Windows already streams cmux.rd/1 over a TCP stream (the
`cmux-rd-windows.yml` live proof: a Mac viewer decodes the Windows desktop over the tailnet).
What Windows lacks is the device hub path: the secure link and the session loop around it.

## 1. Register as `windows`

`cmux-rd windows-host` shares the hub client of `linux-host` (`src/screen_host/`): a P-256
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

Until step 4 the host never turns sharing on (`share on` refuses with the reason), so no Mac
offers to view it; a session the hub still hands it is denied or ended at once.

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

## 4. Serve a hub session (what is missing)

`cmux-rd serve` and the secure link wait on Unix file descriptors. The port:

1. `cmux-rd-link` `net` driver (`net.rs`): the wake pipe becomes a connected loopback UDP
   socket pair, `libc::poll` becomes `WSAPoll` on the socket and the waker,
   `getifaddrs` becomes `GetAdaptersAddresses` (host candidates), `setsockopt` buffer sizes
   through `windows-sys` Winsock. `event_fd()` returns a waitable socket on Windows.
2. `fdwait` / `Carrier::fds` / `Desktop::fd`: a `Wake` abstraction (RawFd on Unix, SOCKET on
   Windows, waited with WSAPoll); the app's stdin lines come from a reader thread that wakes
   the loop through the same loopback socket.
3. A `WindowsDesktop: Desktop` from `GdiCapture` (later Desktop Duplication), `apply_input`
   and the OpenH264 encoder, with a timer as its readiness source.
4. `serve.rs`, `carrier.rs`, `stream.rs`, `desktop.rs` built on Windows; `windows-host run`
   drives `serve` per approved ticket exactly as `linux-host` does (session.rs, rd_doc.rs move
   to `screen_host` with it); then `share on` turns sharing on, and the window-rules plan
   (`cmux-window-rules` `screen_share.rs`) and the Mac's viewer list accept `windows` hosts.
5. CI: `cmux-rd-windows.yml` gains a hub session loopback (the `hub-session-local.py`
   stand-in for the hub's signaling) on the Windows runner.

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
