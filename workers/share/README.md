# cmux share worker

Realtime fan-out for multiplayer workspace sharing: one `ShareSession`
Durable Object per share code relays a host Mac's workspace to guest browsers
at `cmux.com/share/<code>` — terminal render-grid frames, pane layout,
cursors, chat, and (editor-role) guest input back to the host. `PROTOCOL.md`
is the wire spec; `web/services/share/token.ts` mints the tokens this worker
verifies.

## Layout

- `src/protocol.ts` — message types + binary frame header codec (source of
  truth for DO and web viewer; the Mac app mirrors them in Swift).
- `src/session.ts` — pure session state machine (membership, roles, chat,
  subscriptions, host-grace lifecycle). No Cloudflare APIs; fully covered by
  `bun test`.
- `src/jwt.ts` — offline Ed25519 share-token verification.
- `src/do.ts` — Durable Object wiring (hibernation WebSockets, storage,
  alarm) executing the core's effects.
- `src/index.ts` — worker routing + auth boundary.

## Endpoints

| Route | Purpose |
| --- | --- |
| `GET /healthz` | liveness, no auth |
| `GET /v1/share/sessions/<code>/ws` | WebSocket upgrade for host and guests; requires a share JWT (`?token=` or `Authorization: Bearer`) |

## Dev workflow

```bash
bun install
bun run check        # typecheck + tests + wrangler dry-run
bun run dev          # local wrangler dev
```

Deploys mirror workers/presence: production deploys `wrangler.toml`
(`share.cmux.dev`); the shared dev instance deploys with
`wrangler deploy --config wrangler.dev.toml` (never `--name`). Provision the
trust anchor once per environment:

```bash
wrangler secret put SHARE_JWT_PUBLIC_KEY   # SPKI PEM of the web API's signing key
```

The paired private key lives in the web app env as
`CMUX_SHARE_JWT_PRIVATE_KEY_PEM` (see `web/.env.example`).
