# cmux VNC support pieces

The iOS VNC demo app that lived here was removed (cmux#37836): the cmux iOS
app ships Screen Sharing over WebRTC through `Packages/Shared/CmuxScreenKit`.
Two pieces stay because other code uses them:

- `signal/` is the `cmux-vnc-signal` Cloudflare Worker. `CmuxVNCWebRTC`
  signals through it and gets its ICE (TURN) servers from it.
- `host/` builds the screen host app (`make-host-app.sh`) and the marker app
  (`host/marker`) that `MarkerLatencyTests` in `Packages/Shared/CmuxVNCWebRTC`
  measure against.
