# Lane: identity

## Active streams

- Local identity, package P8 (plans/cmux-next/identity.md): launch credentials, the actor stamp, the localhost listener rule, the `frontend` actor and `client.hello`, actor-gated secrets, tailnet mode, HTTP MCP. Owner: P8 lead.

## Landed

- 2026-10-03 (this push) security/listeners: P8 slice 2, the localhost listener rule. New pure crate `cmux-tui/crates/cmux-local-auth` (`ListenerPolicy`, `parse_origin`, constant-time `check_token`). The daemon `--ws` refuses a foreign or `null` Origin and a non-loopback Host with 403 at the handshake, before token or pairing auth; new flags `--ws-allow-origin` / `--ws-allow-host` (the web frontend dev server needs `--ws-allow-origin http://localhost:5173`). acpmux web and WebSocket: the token is mandatory (generated when the config has none), Host/Origin checked on the full parsed head, allowed origins = own + `cmux-agent://pane` + `websocket.allowed_origins`, hosts + `websocket.allowed_hosts` (read at listener start). acpmux peers with no token stop working against an upgraded remote. cmux-remote workspace HTTP refuses every Origin. (P8 lead)
