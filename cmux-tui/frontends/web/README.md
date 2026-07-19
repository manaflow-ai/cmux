# cmux-tui web frontend

[日本語](README.ja.md)

A small third-party-style frontend that proves the protocol-v6 WebSocket API
and the browser entry of the TypeScript SDK are enough to build a natural cmux
client. It renders the authoritative workspace tree, attaches xterm.js to the
active PTY surface, forwards keyboard input, resizes from terminal cells, and
reconciles subscribed invalidation and notification events.

## Install

The app consumes `cmux` through `file:../../bindings/typescript`; it never
depends on an npm-published SDK. Build that local package before installing the
frontend:

```bash
cd ../../bindings/typescript && npm ci && npm run build
cd ../../frontends/web && npm ci
```

## Run

Start these in two terminals from this directory:

```bash
~/.local/bin/cmux-tui --headless --session webfront --ws 127.0.0.1:7681
```

```bash
npm run dev
```

Open `http://localhost:5173`, keep the default WebSocket URL, and connect. Add
`--ws-token <token>` to the server command and enter the same token in the
connect screen to exercise the SDK authentication preamble.

## Remote access and one-tap links

When the page is served from a non-localhost host, the WebSocket URL defaults to `wss://<hostname>:8443` — the convention is to serve the WS endpoint with TLS on port 8443 next to the app (for example with `tailscale serve --https=8443 <ws-port>`). Query parameters `?ws=<url>&token=<token>` prefill and auto-consume the connect form, enabling one-tap links; both are stripped from the address bar immediately so the token never persists in history, and the token is kept in memory only. The last-used WebSocket URL (never the token) is remembered in `localStorage`.

## Screenshot

> Screenshot placeholder — capture the workspace tree, tab strip, attached
> terminal, connection status, and a notification toast here.

## What this demonstrates

- `CmuxClient` and `WebSocketTransport` from `cmux/browser`, including optional
  transport-level token authentication.
- Subscribe-before-snapshot reconciliation for interleaved events and command
  responses.
- `attachSurface()` replay and byte streaming directly into xterm.js.
- Keyboard, trailing-debounced `ResizeObserver` sizing, tab selection,
  reconnect backoff, notifications, and unread attention state.

## Follow-ups

- Render the complete pane split tree. This round intentionally renders only
  the active pane's selected surface.
- Render browser surfaces using their browser-specific attach events.
- Persist connection profiles and add a user-controlled disconnect action.
