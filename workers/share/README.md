# cmux workspace share

Cloudflare Worker and Durable Object service for authenticated cmux workspace sharing. Each high-entropy share code addresses one `ShareRoom`. The room stores access decisions, expiry, one-use ticket nonces, and a bounded chat tail. Terminal grids, panel frames, cursors, and TextBox drafts are relayed live and never written to Durable Object storage.

This package is licensed under `GPL-3.0-or-later`, matching the repository license.

## Security flow

1. The signed-in Mac creates a room with its Stack access token and receives a per-room host capability.
2. A browser visiting `/share/<code>` signs in through Stack Auth.
3. The web API mints a one-use, 60-second Ed25519 ticket bound to that room and verified identity.
4. The browser sends the ticket in `Sec-WebSocket-Protocol`. The Worker verifies it before forwarding to the room.
5. The viewer receives no workspace metadata or frames until the owner allows the verified user ID.
6. Host disconnect starts a two-minute reconnect grace. Room end or eight-hour expiry closes every socket and deletes room state.

The share code is a locator, not authorization. A viewer needs Stack Auth, a valid signed ticket, and an owner approval. The host needs both Stack Auth and the room capability.

## API

| Route | Method | Purpose |
| --- | --- | --- |
| `/healthz` | GET | Liveness, no auth |
| `/v1/shares` | POST | Create a room, Stack bearer required |
| `/v1/shares/:id/socket` | GET upgrade | Host or viewer WebSocket |
| `/v1/shares/:id` | DELETE | End room, owner bearer and capability required |

## Develop

```bash
bun install
bun run typecheck
bun test
bunx wrangler deploy --dry-run --outdir dist
```

Local `.dev.vars` values:

```text
STACK_PROJECT_ID=...
STACK_PUBLISHABLE_CLIENT_KEY=...
SHARE_TICKET_PUBLIC_KEYS_JSON={"dev":"<base64url Ed25519 SPKI DER>"}
```

The web server holds the matching private key in `CMUX_SHARE_TICKET_PRIVATE_KEY_P8`, plus `CMUX_SHARE_TICKET_SIGNING_KID=dev`, `CMUX_SHARE_WORKER_URL`, and `CMUX_SHARE_RATE_LIMIT_ID`. The private key is never installed on Cloudflare. The Worker receives only the public key map.

Use `./scripts/deploy-dev.sh <slug>` for an isolated worker and Durable Object namespace. It refuses shared or production names.

## Production deploy

`.github/workflows/share.yml` typechecks, tests, builds, and manually deploys from `main`. Repository secrets are `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. Provision these Worker secrets once:

```bash
bunx wrangler secret put STACK_PROJECT_ID
bunx wrangler secret put STACK_PUBLISHABLE_CLIENT_KEY
bunx wrangler secret put SHARE_TICKET_PUBLIC_KEYS_JSON
```

Append new Durable Object migration tags in `wrangler.toml`. Never edit the existing `v1` migration.
