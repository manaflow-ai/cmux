# cmux-presence

Realtime device presence service: a Cloudflare Worker with one `TeamPresence`
Durable Object per team. Hosts announce themselves with heartbeats; clients
subscribe to a live presence map with explicit online/offline transitions.
Design, decision memo, and client integration: `docs/presence-service.md`.

## API

All `/v1` routes require `Authorization: Bearer <Stack access token>` and
accept optional team scoping via `X-Cmux-Team-Id` or `?teamId=` (must be a
team the caller belongs to; defaults to the selected team, then the
solo-account user id).

| Route | Method | Purpose |
| --- | --- | --- |
| `/healthz` | GET | liveness (no auth) |
| `/v1/presence/heartbeat` | POST | announce an app instance; `{deviceId, platform, tag?, displayName?, capabilities?, stopping?}`; `stopping: true` is a clean-shutdown goodbye |
| `/v1/presence/snapshot` | GET | one-shot presence map |
| `/v1/presence/subscribe` | GET | WebSocket upgrade or SSE stream: `snapshot` first, then `online` / `offline` / `seen` events |

The heartbeat response returns `heartbeatIntervalMs` (15s) and
`offlineTimeoutMs` (45s); hosts should follow the returned cadence rather than
hardcoding it. An instance that misses heartbeats for the timeout window is
flipped offline by the Durable Object alarm with `reason: "timeout"`.

Devices are owner-bound, mirroring the registry route: the first authenticated
user to announce a `deviceId` owns it, and a heartbeat for that device from a
different team member is rejected with `403 device_owner_mismatch`, so a
co-member cannot forge another member's device online or goodbye it offline.

## Develop

```bash
bun install
bun run typecheck
bun test
bun run dev    # wrangler dev; provide Stack config via .dev.vars or --var
```

`.dev.vars` (gitignored) or `--var` flags supply `STACK_PROJECT_ID` and
`STACK_PUBLISHABLE_CLIENT_KEY` (dev Stack project values). The full local
lifecycle proof, including real Stack sign-in and the alarm-driven timeout, is
`scripts/local-proof.sh` (see header for required env).

## Deploy

Deploys run automatically from `.github/workflows/presence.yml` on push to
main (path-filtered). `wrangler deploy` applies the `[[migrations]]` block in
`wrangler.toml` atomically with the upload, so Durable Object storage classes
can never lag the deployed code.

Required GitHub repository secrets:

- `CLOUDFLARE_API_TOKEN`: API token with Workers Scripts:Edit on the account.
- `CLOUDFLARE_ACCOUNT_ID`: the Cloudflare account id.

One-time Worker secrets (survive deploys; production Stack project values):

```bash
bunx wrangler secret put STACK_PROJECT_ID
bunx wrangler secret put STACK_PUBLISHABLE_CLIENT_KEY
```

Optional plain var `STACK_API_URL` defaults to `https://api.stack-auth.com`.

### Dev/staging instance

A dev instance runs as `cmux-presence-dev` on the team Cloudflare account
(the same one the regatta subrouter deploys to), configured with the dev
Stack project's Worker secrets:

```
https://cmux-presence-dev.debussy.workers.dev
```

Redeploy it manually with `bunx wrangler deploy --name cmux-presence-dev`
(its `STACK_*` Worker secrets are already provisioned and survive deploys).
Point a dev Mac build at it with the `CMUX_PRESENCE_BASE_URL` env override or
the `presenceServiceURL` defaults key, plus `presenceHeartbeatEnabled` (see
`Sources/Cloud/PresenceSettings.swift`).
