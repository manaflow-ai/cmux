<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# cmux share worker

This Cloudflare Worker provides terminal-only multiplayer workspace sharing.
One `ShareSession` Durable Object per share code relays an exact terminal split
layout, render-grid frames, cursors, chat, and editor input. V1 shares at most
one workspace. Browser, agent, and other leaves remain layout placeholders and
cannot be subscribed to, streamed, or controlled.

`PROTOCOL.md` is the wire specification. `web/services/share/token.ts` mints
the 300-second Ed25519 JWTs this worker verifies.

## Layout

- `src/protocol.ts`: wire types, limits, JSON validators, and binary header codec.
- `src/session.ts`: deterministic session state machine and persistence validation.
- `src/ingress.ts`: bounded non-host application ingress accounting.
- `src/outbound.ts`: acknowledged JSON/binary delivery and slow-client cleanup.
- `src/jwt.ts`: offline Ed25519 share-token verification.
- `src/do.ts`: hibernating WebSockets, storage, alarms, and effect execution.
- `src/index.ts`: routing and authentication boundary.

The worker strips `Authorization` and `Cookie` before forwarding a verified
upgrade to the Durable Object. Relayed identity always comes from verified
socket state, never JSON supplied by a client.

## Limits

| Resource | V1 limit |
| --- | ---: |
| Shared workspaces | 1 |
| Connections, host included | 32 |
| Pending access requests | 16 |
| Subscriptions per connection | 64 |
| Client JSON frame | Less than 64 KiB UTF-8 |
| Server JSON frame | Less than 1 MiB UTF-8 |
| Complete binary grid frame | Less than 1 MiB |
| Outstanding delivery credit | 128 entries and less than 2 MiB per socket |
| Non-host application ingress | 120 messages and 512 KiB/socket/s |
| Terminal input message | 16 KiB UTF-8 |
| Terminal input rate | 60/socket/s and 240/room/s |
| Chat message | 4,000 UTF-8 bytes |
| Chat rate | 2/socket/s and 8/room/s |
| Persisted chat | 500 messages and 256 KiB |
| Layout | 128 leaves and depth 16 |
| Cursor updates | 30/socket/s, 240 sources/room/s, 4,096 deliveries/room/s |
| Sub/unsub mutations | 64/socket/s and 256/room/s |
| Persisted grants and denials | 256 each |
| Host disconnect grace | 120 seconds |
| Ended-code tombstone | 10 minutes |

The 33rd connection receives `session_full` and close code `4429`. The 17th
pending request receives `too_many_pending` and `4429`. A host reconnect may
replace the existing host socket without consuming another slot.

Every payload is reserved in the socket's serialized attachment before send,
then followed by `{"t":"ack-request","nonce":...}`. An exact same-socket
`{"t":"ack","nonce":...}` releases its entry. The reservation includes payload,
ACK request, and two conservative WebSocket framing allowances. A prospective
129th entry or total at or above 2 MiB closes only that socket with code `4008`
and reason `slow_client`. Serialization and send failures close with `1011`.
Disconnect effects run immediately, so healthy guests continue and
subscription counts remain current.

Host stop or grace expiry persists an end timestamp and replaces the shared
cursor/grace alarm with a fixed ten-minute cleanup alarm. Early alarms and
hibernation restore re-arm that absolute deadline. Only the boundary alarm
deletes all Durable Object storage. The retention window is twice the
300-second create-token lifetime, so cleanup cannot make the original create
token reusable. Invalid restored lifecycle state is retained and rejected
instead of being deleted early.

Browser WebSockets carry bearer tokens in the query string because browsers
cannot set an `Authorization` header. Every deploy config keeps explicit
redacted Worker logs enabled and sets `observability.logs.invocation_logs` to
false, preventing Cloudflare automatic invocation logs from recording request
URLs. Runtime invariant logs contain event names and numeric metadata only.

## Endpoints

| Route | Purpose |
| --- | --- |
| `GET /healthz` | Unauthenticated liveness check |
| `GET /v1/share/sessions/<code>/ws` | Authenticated host or guest WebSocket |

The WebSocket accepts `?token=` for browsers or `Authorization: Bearer` for
native clients.

## Development

```bash
bun install
bun test
bun run typecheck
wrangler deploy --dry-run --outdir "$(mktemp -d)"
```

`bun scripts/dev-proof.ts --key <pem>` runs the fast deployed flow.
Add `--hibernate` to retain a near-ceiling credit window, idle for 180 seconds,
wake with one exact ACK, require `resync`, and prove post-wake delivery. Local
workerd does not evict Durable Objects, so hibernation mode requires a deployed
development Worker.

Production uses `wrangler.toml` at `share.cmux.dev`. Shared development uses
`wrangler deploy --config wrangler.dev.toml`. Never use `--name`.

Provision the verification key once per environment:

```bash
wrangler secret put SHARE_JWT_PUBLIC_KEY
```

The private key stays in the web application environment as
`CMUX_SHARE_JWT_PRIVATE_KEY_PEM`.

This worker is licensed under GPL-3.0-or-later. See `COPYING`.
