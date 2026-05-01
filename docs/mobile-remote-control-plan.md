# Mobile Remote Control Plan

## Goal

Build a remote-control layer for a running cmux Mac app so a mobile client can inspect and operate cmux sessions on the computer.

This should start as remote control of the desktop app, not a full headless rewrite. cmux currently owns AppKit windows, Ghostty terminal surfaces, WKWebView browser panes, focus state, and local automation through the existing v2 socket protocol.

## What To Build

- **Remote server inside cmux**
  - Runs only when enabled in Settings.
  - Listens on localhost by default.
  - Supports an explicit LAN mode for phone access.
  - Exposes HTTP plus an event stream over SSE or WebSocket.
  - Reuses existing `TerminalController` v2 methods instead of duplicating app logic.

- **RPC endpoint**
  - Add `POST /rpc`.
  - Accept JSON shaped like `{ "method": "workspace.list", "params": {} }`.
  - Route requests through the existing cmux v2 socket dispatcher.
  - Return the existing v2 JSON response shape.

- **Snapshot endpoint**
  - Add `GET /snapshot`.
  - Return current app state:
    - windows
    - workspaces
    - panes
    - surfaces
    - focused IDs
    - unread notifications
    - surface types such as terminal, browser, and markdown
    - latest terminal text preview where appropriate

- **Event stream**
  - Add `GET /events`.
  - Use Server-Sent Events for v1 with coarse `snapshot_changed` events.
  - Authenticate browser `EventSource` connections through an event session cookie created by authenticated `POST /events/session`.
  - Keep query-token event auth limited to localhost compatibility; never allow URL query tokens in LAN mode.
  - Push updates for:
    - workspace created, closed, renamed, or selected
    - pane and surface changes
    - notification created or cleared
    - feed item created or resolved
    - terminal output changed, throttled
    - browser URL, title, and loading changes

- **Authentication and pairing**
  - Add a Remote Access settings section.
  - Generate a pairing token or password.
  - Show a QR code with the connection URL.
  - Put pairing tokens in the URL fragment so the token is not sent with the initial static page request.
  - Require auth for every remote request.
  - Support token rotation and revocation.
  - Never expose unauthenticated control APIs on LAN.

- **Network discovery**
  - Start with local-only mode.
  - Add optional LAN mode.
  - Display reachable URLs in Settings.
  - Advertise LAN mode with mDNS/Bonjour in a later iteration.
  - Add Tailscale or Cloudflare Tunnel guidance later for away-from-LAN access.

- **Mobile web client / PWA**
  - Provide a responsive browser UI for mobile.
  - Main views:
    - workspace list
    - current workspace detail
    - pane and surface list
    - terminal reader
    - input composer
    - notifications and feed
    - browser controls
  - Make it installable on the iOS home screen.

- **Terminal control UI**
  - Read current terminal output through `surface.read_text`.
  - Send input through `surface.send_text`.
  - Send common keys through `surface.send_key`.
  - Provide buttons for:
    - Enter
    - Esc
    - Ctrl-C
    - arrows
    - Tab
    - common command/control shortcuts where supported

- **Workspace and pane controls**
  - Create, select, rename, and close workspaces.
  - Split panes.
  - Focus panes and surfaces.
  - Create terminal and browser surfaces.
  - Close surfaces.
  - Jump to the latest unread item.

- **Browser pane controls**
  - Open URLs.
  - Navigate back and forward.
  - Reload.
  - Read the current URL and title.
  - Later, expose screenshot, snapshot, click, and fill APIs from existing `browser.*` methods.

- **Feed and agent interaction**
  - Show pending permission, question, and exit-plan items.
  - Reply from mobile.
  - Jump to the related cmux session.
  - Mark items resolved or read.

- **Safety policy**
  - Remote commands must respect the existing focus policy.
  - Non-focus commands should not raise or activate the Mac app.
  - Dangerous commands need explicit user action.
  - Terminal input must target a selected surface, never an ambiguous one.

- **Tests**
  - Unit tests for auth and token validation.
  - Runtime tests for `POST /rpc` routing into existing v2 methods.
  - Event-stream tests for notifications, feed, and workspace updates.
  - Mobile UI smoke tests once a web client exists.
  - Avoid tests that only grep source files or assert implementation shape.

- **Documentation**
  - Add a remote-access docs page.
  - Explain LAN and Tailscale setup.
  - Explain the security model.
  - Document API basics and example requests.

## Recommended MVP Order

1. Add `CMUXRemoteServer` with authenticated `POST /rpc`.
2. Add `GET /snapshot`.
3. Build a minimal mobile web UI for workspace list, terminal read, send text, and send keys.
4. Add SSE or WebSocket events.
5. Add feed and notification actions.
6. Add LAN mode and pairing QR code.
7. Add mDNS/Bonjour discovery.
8. Add browser controls and richer mobile UX.
