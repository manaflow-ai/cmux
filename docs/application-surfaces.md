# Native application surfaces

CMUX application surfaces display an existing native macOS window inside a
workspace tab. They are distinct from browser surfaces and contain no web view.

ScreenCaptureKit supplies GPU-backed window frames. CMUX forwards mouse,
keyboard, and scrolling events to the selected process. The application keeps
running independently when the surface closes.

## Permissions

Application surfaces require macOS Screen Recording permission. Interactive
input also requires Accessibility permission. macOS presents these approvals
and does not provide a supported way for CMUX to grant them silently.

CMUX verifies that the native window still belongs to the requested process
before capture and while forwarding input. Input fails closed when ownership
changes or Accessibility permission is unavailable. Hidden application surfaces
stop capturing until they become visible again.

Application control is disabled when the automation socket uses `allowAll`
mode. Use `cmuxOnly`, `automation`, or password mode so arbitrary local clients
cannot turn CMUX's Accessibility permission into native application input.

## CLI

List capturable windows:

```sh
cmux --json list-application-windows
```

Create an application surface from a listed window:

```sh
cmux new-surface \
  --workspace workspace:1 \
  --type application \
  --native-window-id 123 \
  --process-id 456 \
  --title Preview \
  --frame-rate 60 \
  --focus true
```

Application lifecycle remains outside CMUX. Launch or stop the application with
its own CLI, launcher, or automation, then attach the resulting window using the
CMUX CLI.

`surface.split` does not accept `type=application`; use `surface.create` with
`window_id_native` and `process_id`.
