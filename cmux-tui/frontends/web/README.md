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
~/.local/bin/cmux-tui --headless --session webfront --ws 127.0.0.1:7681 --ws-token change-me \
  --ws-allow-origin http://localhost:5173
```

```bash
npm run dev
```

Open `http://localhost:5173`, keep the default WebSocket URL, and connect. The
browser and TUI show the same six-digit code. Approve it in the TUI with Enter.
`--ws-token <token>` remains available as a non-interactive automation bypass.
The listener refuses browser pages from any other origin and requests whose
`Host` is not loopback; `--ws-allow-origin` adds the dev server page, and
`--ws-allow-host` adds a name such as the `tailscale serve` host. Behind
`tailscale serve --https=8443`, pass both
`--ws-allow-origin https://<name>.ts.net:8443 --ws-allow-host <name>.ts.net`.

## Served by the daemon (one URL, no dev server)

```bash
scripts/serve-from-daemon.sh --session web --port 7690
```

builds this app into a page bundle folder as the page `web`, starts a headless
daemon whose loopback listener also serves that folder (`CMUX_TUI_PAGES_DIR`,
spec/transports.md "App listener and page files") and prints
`http://127.0.0.1:7690/pages/web/#token=…`. A page under `/pages/` connects to
its own origin, and a token in the fragment connects at once. On a Cloud or
lane VM, `ssh -L 7690:127.0.0.1:7690 HOST` and open the URL on your machine.
`scripts/measure-in-browser.mjs URL OUTDIR` drives headless Chrome against it
and writes first paint, keystroke-to-echo and two screenshots.

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
