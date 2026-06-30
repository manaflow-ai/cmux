# cmux Collaboration Relay

This Worker is the Phase 1 cmux Multiplayer relay. It is deliberately small: it creates invite-token gated sessions, accepts WebSocket peers, forwards opaque collaboration frames, and drops peers that stop heartbeating.

## Local Development

```bash
bun install
bun run typecheck
bun test
bun run dev
```

Downloadable cmux builds default to the production relay at `https://collaboration.cmux.dev`. For local development, override the relay URL with `http://localhost:8787` in the collaboration dialog or with `cmux collaboration create --relay-url http://localhost:8787`.

## Deploy

Pushes to `main` that touch this worker run `.github/workflows/collaboration.yml`, which typechecks, runs unit tests, dry-runs Wrangler, then deploys to Cloudflare with Durable Object migrations applied atomically.

```bash
bun run check
bun run deploy
```

The deploy job requires repository secrets `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. `wrangler.toml` binds the `COLLABORATION_SESSIONS` Durable Object namespace and exposes the production custom domain `collaboration.cmux.dev`; the macOS client converts `https://` relay URLs to `wss://` for WebSocket joins.

After deployment, smoke-test the public relay:

```bash
bun run smoke:relay
```

The smoke test performs a real health check, session creation, two WebSocket peer joins, heartbeat handling, and document frame forwarding. Set `CMUX_COLLABORATION_RELAY_URL` or pass a URL to test another relay:

```bash
CMUX_COLLABORATION_RELAY_URL=http://localhost:8787 bun run smoke:relay
bun run smoke:relay https://collaboration.cmux.dev
```

## HTTP API

### `GET /healthz`

Returns a static health response:

```json
{ "ok": true, "service": "cmux-collaboration" }
```

### `POST /v1/collaboration/sessions`

Creates an in-memory relay session and returns:

```json
{
  "sessionID": "ABCD-1234",
  "sessionCode": "ABCD-1234",
  "token": "invite-token"
}
```

### `GET /v1/collaboration/sessions/:sessionCode/connect`

Upgrades to WebSocket. Required query parameters:

- `token`: invite token returned by session creation.
- `peerID`: stable local peer ID.
- `displayName`: peer display name.
- `color`: presence color.

## Forwarded Frames

The relay treats non-heartbeat frames as opaque JSON envelopes with a string `type` field. It forwards them to every other peer with `fromPeerID` and `receivedAt` added. Phase 1 clients currently use:

- `document.update`
- `document.snapshot.request`
- `document.snapshot`
- `presence.update`
- `terminal.open`
- `terminal.output`
- `terminal.input`
- `terminal.pointer`
- `terminal.selection`
- `terminal.close`

`peer.heartbeat` updates liveness and is not forwarded.

## Phase 1 Non-Guarantees

- No repository-wide file sync.
- No Git automation.
- No account auth or ACLs beyond the invite token.
- No NAT traversal or direct peer-to-peer transport.
- Durable Object active memory is the session state; document content is never persisted by the relay.
