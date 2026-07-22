# cmux-tui web frontend

[日本語](README.ja.md)

A small third-party-style frontend that proves the protocol-v9 WebSocket API
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
~/.local/bin/cmux-tui --headless --session webfront --ws 127.0.0.1:7681 --ws-token change-me
```

```bash
npm run dev
```

Open `http://localhost:5173`, keep the default WebSocket URL, and connect. The
browser and TUI show the same six-digit code. Approve it in the TUI with Enter.
`--ws-token <token>` remains available as a non-interactive automation bypass.

## Remote access and one-tap links

When served from a non-localhost host, the WebSocket URL defaults to `wss://<hostname>:8443`. Put TLS in front of the server, for example with `tailscale serve --https=8443 <ws-port>`. `?ws=<url>` is consumed from the address bar and the last URL is remembered in `localStorage`. For automation, `?ws=<url>#token=<token>` supplies a static token in the fragment, which never enters the HTTP request and is removed immediately without being persisted.

## Screenshot

> Screenshot placeholder — capture the workspace tree, tab strip, attached
> terminal, connection status, and a notification toast here.

## What this demonstrates

- `CmuxClient` and `WebSocketTransport` from `cmux/browser`, including TUI-approved
  pairing and an optional static-token bypass.
- Subscribe-before-snapshot reconciliation for interleaved events and command
  responses.
- `attachSurface()` replay and byte streaming directly into xterm.js.
- Keyboard, trailing-debounced `ResizeObserver` sizing, tab selection,
  reconnect backoff, notifications, and unread attention state.
- Stable split-id rendering and exact divider resizing through
  `set-split-ratio`.
- Zellij-style stack layouts with one expanded pane and collapsed title rows.

## Follow-ups

- Render browser surfaces using their browser-specific attach events.
- Persist connection profiles and add a user-controlled disconnect action.
