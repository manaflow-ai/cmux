# Deploying the device hub

The device hub (`docs/device-hub/PROTOCOL.md`) is one Worker with two SQLite
Durable Object classes, `UserDO` and `SessionDO`. It deploys to Lawrence's
Cloudflare account. `wrangler.toml` commits no `account_id`; the deploy shell
provides it. The top level of `wrangler.toml` is production; `[env.dev]` is
dev. Bindings, vars and migrations are repeated under `[env.dev]`, because
environments do not inherit them. The two are separate Workers, so their
Durable Objects, storage and secrets are separate too.

| Environment | Worker | URL |
|---|---|---|
| dev | `cmux-device-hub-dev` | `https://cmux-device-hub-dev.debussy.workers.dev` |
| production | `cmux-device-hub` | `https://cmux-device-hub.debussy.workers.dev` |

The cmux-next app builds both addresses in (`DeviceHubSettings` in
`Packages/macOS/CmuxNext/Sources/CmuxNextSettings`): DEV builds use the dev
hub, every other build the production hub. A DEV build's Settings ›
Development › Device Hub Address overrides it; empty means the built-in hub.
Both are on workers.dev: a custom domain (as `workers/presence` uses) would
add a DNS record, which this hub does not need.

## Dev deploy

Run from `workers/device-hub` with wrangler signed in to the account.

```bash
export CLOUDFLARE_ACCOUNT_ID=0c1675e0def6de1ab3a50a4e17dc5656
npm ci

# 1. Deploy the code and the v1 Durable Object migration.
npx wrangler deploy --env dev

# 2. Server keys. Each command generates a fresh P-256 private JWK and pipes it
#    straight into the secret; the value never reaches the terminal or a file.
node scripts/gen-key.mjs | npx wrangler secret put SESSION_KEY --env dev
node scripts/gen-key.mjs | npx wrangler secret put TICKET_KEY --env dev

# 3. cmux relay credentials (Cloudflare Realtime TURN), from the
#    1Password item "Cloudflare TURN Server API Key" in the Shared vault.
op read "op://Shared/lqvg75d4awzbveq7ny5gyfeyd4/credential" \
  | npx wrangler secret put TURN_KEY_API_TOKEN --env dev
# The key id is in the item's notes. Check that exactly one 32-hex id is found
# (prints a count, not the id), then store it.
op read "op://Shared/lqvg75d4awzbveq7ny5gyfeyd4/notesPlain" | grep -oE '[0-9a-f]{32}' | sort -u | wc -l
op read "op://Shared/lqvg75d4awzbveq7ny5gyfeyd4/notesPlain" | grep -oE '[0-9a-f]{32}' | head -1 \
  | npx wrangler secret put TURN_KEY_ID --env dev

# 4. Health check.
curl -fsS https://cmux-device-hub-dev.debussy.workers.dev/v1/health
```

Without `TURN_KEY_ID` and `TURN_KEY_API_TOKEN`, the Worker still runs:
subscribers get `ice: []`, as free users do, and the apps fall back to direct
paths and the user's own relays.

Rotating `SESSION_KEY` signs every device out (their hub sessions stop
verifying and their sealed Stack tokens stop opening; the apps exchange their
Stack token again). Rotating `TICKET_KEY`
invalidates tickets that are less than 60 s old. Neither touches stored data.

## Production deploy

The same steps without `--env dev`. Wrangler asks for an explicit target on
the top level, so pass `--env=""`. Production generates its own keys; never
copy the dev keys.

```bash
export CLOUDFLARE_ACCOUNT_ID=0c1675e0def6de1ab3a50a4e17dc5656
npx wrangler deploy --env=""
node scripts/gen-key.mjs | npx wrangler secret put SESSION_KEY --env=""
node scripts/gen-key.mjs | npx wrangler secret put TICKET_KEY --env=""

# TURN: read each value into a variable first, so a failed or unapproved
# `op read` stores nothing (piping it straight in stores an empty secret).
tok=$(op read "op://Shared/lqvg75d4awzbveq7ny5gyfeyd4/credential")
kid=$(op read "op://Shared/lqvg75d4awzbveq7ny5gyfeyd4/notesPlain" | grep -oE '[0-9a-f]{32}' | head -1)
[ -n "$tok" ] && [ ${#kid} -eq 32 ] \
  && printf %s "$tok" | npx wrangler secret put TURN_KEY_API_TOKEN --env="" \
  && printf %s "$kid" | npx wrangler secret put TURN_KEY_ID --env=""
unset tok kid

npx wrangler secret list --env=""      # names only
curl -fsS https://cmux-device-hub.debussy.workers.dev/v1/health
```

Check that production refuses a Stack development-project token: POST
`{"token": "<dev access token>"}` to `/v1/auth/stack` returns 401 "access
token is not for an accepted project" (the dev hub returns 200 for the same
token).

### Who gets the cmux relay

cmux billing decides, not the hub. Before each ticket and each
`/v1/sessions/:id/ice`, the hub asks the cmux web backend of the user's Stack
project for the plan (`GET /api/billing/plan`) with the user's own Stack
access token, which the hub session carries sealed (`src/billing.ts`). The
relay goes to a personal Pro or Max plan, or a billing team on Team. Free, Go,
and any failed or timed-out lookup (5 s) get `ice: []`; sessions still connect
directly or through the user's own relays. Logs show only the outcome
(`relay entitlement: paid|free|error`), never a token.

`BILLING_ORIGINS` is a plain var, a comma list of
`<stackProjectId>=<https origin>`: production maps the prod project to
`https://cmux.com`; dev also maps the development project to
`https://cmux-staging.vercel.app`. A project without an entry never gets the
relay. To grant a test account the relay, give it a plan in that backend's
billing (on staging, the admin plan grant), not a hub setting.

### Stack projects

`STACK_PROJECT_IDS` lists the Stack Auth projects whose tokens the hub
accepts. Dev accepts cmux prod (`9790718f-…`) and the Stack development
project (`454ecd03-…`) that DEBUG/tagged builds sign in to; production
accepts prod only. Users are keyed by project, so the same Stack user id in
two projects is two hub users.

## Checks before a deploy

Tests and installs run on a cmux Mac mini, not the laptop:

```bash
rsync -a --delete --exclude node_modules --exclude .wrangler --exclude .dev.vars \
  workers/device-hub/ mini-cmux15:device-hub-work/src/
ssh mini-cmux15 'cd ~/device-hub-work/src && export PATH=$HOME/.local/bin:$PATH \
  && npm ci && npx tsc --noEmit && npx vitest run && npx wrangler deploy --dry-run --env dev --outdir /tmp/dh-dist'
```

## Local `wrangler dev` (integration only)

```bash
ssh mini-cmux15 'cd ~/device-hub-work/src && export PATH=$HOME/.local/bin:$PATH \
  && node scripts/gen-dev-secrets.mjs .dev.vars \
  && npx wrangler dev --ip 0.0.0.0 --port 8799 --persist-to ~/device-hub-work/state'
curl -fsS http://cmux15.tail137216.ts.net:8799/v1/health
```

This is plain HTTP on the tailnet. The cmux apps' App Transport Security
allows insecure loads only for `cmux-loopback.localtest.me`, so apps need the
https dev deployment above, not this server.
