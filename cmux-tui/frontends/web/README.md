# cmux-tui web frontend

[日本語](README.ja.md)

A small third-party-style frontend that proves the protocol-v12 WebSocket API
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

## Connect to the Mac app

The same frontend can continue a live terminal session owned by the cmux Mac
app. Start the opt-in bridge from a local terminal:

```bash
cmux serve-web start --label "Safari"
```

Choose **Mac app** on the connection screen, keep the printed WebSocket
endpoint, and paste the single-display grant token. The token is sent in the
first WebSocket message, never in the URL, and remains in browser memory only
for reconnects. Grants live only for the current cmux process; stopping or
relaunching cmux invalidates them. A grant can read and type into the Mac
terminals listed by the client, so paste it only into a trusted copy of this
frontend. Each browser gets an independent revocable grant:

```bash
cmux serve-web grants
cmux serve-web revoke <grant-id>
cmux serve-web stop
```

The bridge binds to loopback by default. Remote binding must name a specific
Tailscale `100.64.0.0/10` address; wildcard and ordinary LAN addresses are
rejected. Pages served over HTTPS need a private TLS proxy in front of the
bridge and should connect to its `wss://.../cmux` endpoint. The opening
WebSocket upgrade accepts loopback origins, the exact Tailscale bind address,
or a private HTTPS `*.ts.net` origin; other webpages are rejected during the
HTTP upgrade instead of holding a 10-second authenticated-hello slot.

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
- A grant-scoped Mac runtime adapter for workspace discovery, terminal replay,
  byte streaming, input, and viewport reporting without exposing the broader
  local control API.
- Keyboard, trailing-debounced `ResizeObserver` sizing, tab selection,
  reconnect backoff, notifications, and unread attention state.
- Stable split-id rendering and exact divider resizing through
  `set-split-ratio`.
- Zellij-style stack layouts with one expanded pane and collapsed title rows.

## Follow-ups

- Render browser surfaces using their browser-specific attach events.
- Persist connection profiles and add a user-controlled disconnect action.
