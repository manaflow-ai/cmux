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
