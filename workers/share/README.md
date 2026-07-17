# cmux-share

Multiplayer workspace share: a Cloudflare Worker with one `ShareSession`
Durable Object per share id. A cmux macOS host streams one workspace
read-only; authenticated web viewers at `cmux.com/share/<id>` connect after
explicit per-user host approval. Design and wire protocol:
`plans/feat-multiplayer-share/DESIGN.md`.

## License

This package is GPL-3.0-or-later (see `LICENSE`; every `src/*.ts` file
carries an SPDX header). Viewers connect from the proprietary cmux web app
over the wire protocol documented in the design doc; the protocol boundary is
the WebSocket JSON frames, and the web app links nothing from this package.

## API

| Route | Method | Purpose |
| --- | --- | --- |
| `/healthz` | GET | liveness (no auth) |
| `/v1/share/create` | POST | Stack bearer auth; body `{ title? }`; returns `{ shareId, hostToken, url }` |
| `/v1/share/:id/host` | GET | WebSocket upgrade, host lane (`?token=<hostToken>`) |
| `/v1/share/:id/ws` | GET | WebSocket upgrade, viewer lane (`?access_token=<Stack access token>`) |

`shareId` is 22 chars base62 (unguessable). The host token is minted at
create and only its SHA-256 hash is stored; a new host connection supersedes
the old one. Viewers are pending until the host answers a `join_request`;
verdicts are remembered per Stack user id for the life of the session. The DO
relays `layout`/`term`/`term_resize`/`textbox` frames to approved viewers
without storing terminal data, stamps and rebroadcasts `cursor` (30/s per
sender) and `chat` (last 200 kept and replayed to newly approved viewers),
and broadcasts the `presence` participant list on every change. The session
ends when the host sends `{type:"end"}` or stays disconnected for 60s; the DO
sends `{type:"ended"}`, closes all sockets, and deletes all storage.

## Secrets

Stack Auth config is provisioned once as Worker secrets (never `[vars]`,
which would be overwritten on deploy):

```bash
wrangler secret put STACK_PROJECT_ID
wrangler secret put STACK_PUBLISHABLE_CLIENT_KEY
```

Optional plain var `STACK_API_URL` defaults to `https://api.stack-auth.com`.

## Development

```bash
bun install
bun run typecheck   # tsgo, src + tests
bun test            # pure-logic tests (no miniflare)
bun run check       # typecheck + tests + wrangler deploy --dry-run
```
