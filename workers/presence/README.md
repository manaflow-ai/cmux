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

Redeploy it manually with `bunx wrangler deploy --config wrangler.dev.toml`
(its `STACK_*` Worker secrets are already provisioned and survive deploys).

> [!IMPORTANT]
> Use `--config wrangler.dev.toml`, NOT `--name cmux-presence-dev`. The default
> `wrangler.toml` carries the **production** `presence.cmux.dev` custom domain;
> `--name` only overrides the worker name, so it inherits that route and STEALS
> the production domain (detaching it from `cmux-presence`, which breaks prod
> auth since the dev worker uses the dev Stack project). `wrangler.dev.toml` has
> `workers_dev = true` and no custom domain, so the dev instance stays on its
> own `*.workers.dev` URL.
Point a dev Mac build at it with the `CMUX_PRESENCE_BASE_URL` env override or
the `presenceServiceURL` defaults key, plus `presenceHeartbeatEnabled` (see
`Sources/Cloud/PresenceSettings.swift`).

### Working on the worker with several people at once

`cmux-presence-dev` is a **single shared instance** — last deploy wins, and an
unmerged feature (e.g. the paired-Mac backup, which only exists on its branch)
lives ONLY on whoever deployed last. So don't push your branch onto the shared
worker: get your own **isolated** one instead.

```
./scripts/deploy-dev.sh           # deploys cmux-presence-dev-<your-id>
```

Each `cmux-presence-dev-<slug>` is a separate worker with its **own Durable
Object namespace**, so presence + paired-Mac-backup state is fully isolated per
developer — multiple people dogfood worker changes simultaneously without
clobbering each other or the shared baseline. Because Cloudflare secrets are
scoped to each Worker, the script also provisions the new Worker with the dev
Stack Auth values from your shell environment or `.dev.vars`
(`STACK_PROJECT_ID`, `STACK_PUBLISHABLE_CLIENT_KEY`, optional `STACK_API_URL`);
it refuses to deploy if those values are missing. The script prints the worker
URL and the env var to export:

```
export CMUX_PRESENCE_BASE_URL=https://cmux-presence-dev-<slug>.<subdomain>.workers.dev
```

Point **every** build in your dogfood loop at it (the Mac that heartbeats AND the
iPhone that subscribes/backs up must share one worker):

- **Mac:** `CMUX_PRESENCE_BASE_URL` env, or `defaults write <tagged-bundle>
  presenceServiceURL <url>`. Resolved by `PresenceSettings`.
- **iOS:** a tapped device app sees no shell env, so the override is read from the
  app's **Info.plist key `CMUXPresenceBaseURL`** (and from `presenceServiceURL`
  UserDefaults / the `CMUX_PRESENCE_BASE_URL` launch env). Resolution precedence:
  env → UserDefaults → Info.plist → Debug default. `ios/scripts/reload.sh` bakes
  `$CMUX_PRESENCE_BASE_URL` into that Info.plist key (next to `CMUXDevTag`, via the
  `CMUX_PRESENCE_BASE_URL` build setting in `ios/Config/Shared.xcconfig` +
  `Info.plist`), so once it is exported a normally-tapped dev device build talks to
  your worker. Empty by default, so release/TestFlight builds are unaffected.

Leave `CMUX_PRESENCE_BASE_URL` unset to use the shared `cmux-presence-dev`
baseline. The durable fix for any feature is to **merge it** — then it ships on
prod via CI and anyone deploying dev from `main` carries it, no coordination
needed.
