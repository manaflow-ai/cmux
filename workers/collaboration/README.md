# cmux Collaboration Relay

This Worker is the Phase 1 cmux Multiplayer relay. It is deliberately small: it creates invite-token gated sessions, accepts WebSocket peers, forwards opaque collaboration frames, and drops peers that stop heartbeating.

## Local Development

```bash
bun install
bun run typecheck
bun test
bun run dev
```

The local relay defaults to `http://localhost:8787`. In cmux, open a plain-text file preview, click **Collaborate**, enter that relay URL, and choose **Create Session**. A second cmux instance can join with the displayed session code and invite token.

## Deploy

```bash
bun run check
bun run deploy
```

`wrangler.toml` binds the `COLLABORATION_SESSIONS` Durable Object namespace. Production deployments should expose the Worker behind HTTPS; the macOS client converts `https://` relay URLs to `wss://` for WebSocket joins.

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

`peer.heartbeat` updates liveness and is not forwarded.

## Phase 1 Non-Guarantees

- No repository-wide file sync.
- No Git automation.
- No account auth or ACLs beyond the invite token.
- No NAT traversal or direct peer-to-peer transport.
- No terminal sharing.
- Durable Object active memory is the session state; document content is never persisted by the relay.
