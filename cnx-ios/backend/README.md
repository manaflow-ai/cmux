# cnx-ios-api

Cloudflare Worker for the cnx-ios app. It implements the HTTP and signaling
parts of [`../PROTOCOL.md`](../PROTOCOL.md), which is the contract.

- `src/index.ts`: routes, Stack JWT auth, validation.
- `src/team-hub.ts`: `TeamHub` Durable Object, one per team (SQLite-backed,
  hibernating WebSockets): signaling admission, Mac presence, WireGuard relay,
  60 s membership cache.
- `src/store.ts`, `src/schema.ts`, `drizzle/`: PlanetScale Postgres through
  Hyperdrive (Drizzle). Tests use an in-memory store.
- `src/stack.ts`: Stack team membership and invitations.
- `src/ice.ts`: Cloudflare Realtime TURN credentials.

## Environments

| Env | Worker | URL | Database |
| --- | --- | --- | --- |
| `dev` | `cnx-ios-api-dev` | https://cnx-ios-api-dev.debussy.workers.dev | PlanetScale `cmux/cnx-ios`, branch `main`, role `cnx-ios-dev`, Hyperdrive `cnx-ios-dev` (`e4fd2e88cfcd4f00841ddc5b49c3ee06`) |
| `prod` | `cnx-ios-api-prod` | not deployed | to create: a prod branch/role, its Hyperdrive config, then replace `REPLACE_WITH_PROD_HYPERDRIVE_ID` and `INVITE_CALLBACK_URL` in `wrangler.jsonc` |

Cloudflare account `0c1675e0def6de1ab3a50a4e17dc5656`. Run wrangler as
`bunx wrangler@4` (OAuth login).

## Secrets

Set per environment with `bunx wrangler@4 secret put <NAME> --env <env>`.
Pipe values from 1Password; never paste or echo them.

| Name | Source | Required |
| --- | --- | --- |
| `TURN_KEY_ID` | 1Password `Cloudflare TURN Server API Key` (vault Shared), the "Turn Token ID" in its notes | for TURN (else `/v1/ice` is STUN only) |
| `TURN_KEY_API_TOKEN` | same item, field `credential` | for TURN |
| `STACK_SECRET_SERVER_KEY` | Stack server key of the env's project | optional; without it membership and invites use the caller's own token |

```bash
op item get lqvg75d4awzbveq7ny5gyfeyd4 --fields notesPlain | grep -oE '[0-9a-f]{32}' | head -1 | tr -d '\n' \
  | bunx wrangler@4 secret put TURN_KEY_ID --env dev
op read "op://Shared/lqvg75d4awzbveq7ny5gyfeyd4/credential" | tr -d '\n' \
  | bunx wrangler@4 secret put TURN_KEY_API_TOKEN --env dev
```

Check `op whoami` first: a failed `op` call pipes an empty value and wrangler
stores it.

The database URL is only in the Hyperdrive config. To create one:

```bash
pscale role create cnx-ios <branch> <role> --org cmux --inherited-roles postgres --format json > /private/path/role.json
bunx wrangler@4 hyperdrive create cnx-ios-<env> --connection-string="$(jq -r '.database_url | split("?")[0]' /private/path/role.json)"
```

## Migrations

```bash
bun install
bunx drizzle-kit generate --name <change>       # after editing src/schema.ts
DATABASE_URL="$(jq -r .database_url /private/path/role.json)" bunx drizzle-kit migrate
```

## Test and deploy

```bash
bun install
bunx tsc -p .
bunx vitest run                 # workerd via @cloudflare/vitest-pool-workers
bunx wrangler@4 deploy --env dev
```

## Live smoke test

`scripts/smoke.ts` exercises health, auth rejection, ICE, device upsert, team
Macs, prefs, and a two-client WebSocket exchange (hello, offer/answer, relay
rewrite, refusal, offline presence) against the deployed Worker. It prints
PASS/FAIL lines only, never tokens.

```bash
# The dev test account is 1Password item sirnczouv25kkvpzlbhnpxpqo4.
STACK_EMAIL="$(op item get sirnczouv25kkvpzlbhnpxpqo4 --fields username)" \
STACK_PASSWORD="$(op read 'op://Development/sirnczouv25kkvpzlbhnpxpqo4/password')" \
  bun scripts/smoke.ts
# or with a token already saved to a 0600 file:
CNX_TOKEN_FILE=/private/path/token bun scripts/smoke.ts
```

`CNX_BASE_URL` selects another deployment.
