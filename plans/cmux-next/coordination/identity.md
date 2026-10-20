# Lane: identity

## Active streams

- Local identity, package P8 (plans/cmux-next/identity.md): launch credentials, the actor stamp, the localhost listener rule, the `frontend` actor and `client.hello`, actor-gated secrets, tailnet mode, HTTP MCP. Owner: P8 lead.

## Landed

- 2026-10-20 (socket-auth audit phase 2, this push): every local line connection records its kernel peer process key at accept, including legacy clients that omit `client-hello`; an unproved local user whose peer belongs to a live terminal session is attributed as that `terminal`, while a verified app keeps its stronger `frontend` actor. Omitting `credential` therefore cannot become `user_local` to call `credential.mint` or `credential.rotate`; a presented launch credential still overrides local terminal ancestry, and the detached acpmux daemon remains the local owner that mints per-session credentials. (socket-auth lead)
- 2026-10-03 (this push) security/listeners: P8 slice 2, the localhost listener rule. New pure crate `cmux-tui/crates/cmux-local-auth` (`ListenerPolicy`, `parse_origin`, constant-time `check_token`). The daemon `--ws` refuses a foreign or `null` Origin and a non-loopback Host with 403 at the handshake, before token or pairing auth; new flags `--ws-allow-origin` / `--ws-allow-host` (the web frontend dev server needs `--ws-allow-origin http://localhost:5173`). acpmux web and WebSocket: the token is mandatory (generated when the config has none), Host/Origin checked on the full parsed head, allowed origins = own + `cmux-agent://pane` + `websocket.allowed_origins`, hosts + `websocket.allowed_hosts` (read at listener start). acpmux peers with no token stop working against an upgraded remote. cmux-remote workspace HTTP refuses every Origin. (P8 lead)
- 2026-10-03 (same push) shared-surface moves for the god-file budget, no behavior change: the daemon WebSocket listener moved from cmux-tui-core `server.rs` to `server/websocket_listener.rs` (public paths re-exported); the inline tests of cmux-tui `main.rs` and cmux-remote `http.rs` moved to `main_tests.rs` and `http_tests.rs`. acpmux `daemon.log` is created 0600. (P8 lead)
