# cmux-coderouter

Cloudflare Worker data plane for the cmux coderouter gateway. It verifies
`crk_` caller keys, asks a per-team `PoolCoordinator` Durable Object for the
best credential, forwards requests to the matching upstream API, and buffers
usage events for the control plane.

The control plane owns key minting, credential management, OAuth connect
flows, and billing. This worker keeps hot-path state close to traffic:
credential pools, sticky conversation assignments, OAuth token chains, limit
state, and a small usage-event buffer.

## API

| Route | Auth | Purpose |
| --- | --- | --- |
| `GET /healthz` | none | liveness |
| `GET /v1/models` | none | worker catalog snapshot |
| `/anthropic/*` | `crk_` key | strip `/anthropic`, forward path and query unchanged |
| `/openai/v1/*` | `crk_` key | forward as `/v1/*` |
| `/codex/*` | `crk_` key | forward as `/backend-api/codex/*` |
| `POST /internal/pools/:poolId/sync` | internal bearer token | push a full pool config |
| `POST /internal/pools/:poolId/seed-oauth` | internal bearer token | seed an OAuth chain into the pool |

Caller keys are accepted as `Authorization: Bearer crk_...` or
`x-api-key: crk_...`. Internal routes use
`Authorization: Bearer $CODEROUTER_INTERNAL_TOKEN` and are never routed through
caller-key auth.

## Client wiring examples

API-family traffic can point its base URL at:

```bash
export ANTHROPIC_BASE_URL="https://coderouter.cmux.dev/anthropic"
export ANTHROPIC_AUTH_TOKEN="crk_..."
```

```toml
chatgpt_base_url = "https://coderouter.cmux.dev/codex"
openai_base_url = "https://coderouter.cmux.dev/openai/v1"
api_key = "crk_..."
```

## Environment

Plain vars in `wrangler.toml`:

- `CONTROL_PLANE_BASE_URL`: production defaults to `https://cmux.com`.

Worker secrets are provisioned with `wrangler secret put`, not `[vars]`, so a
deploy does not overwrite dashboard-set values:

```bash
bunx wrangler secret put CODEROUTER_KEY_SIGNING_SECRET
bunx wrangler secret put CODEROUTER_INTERNAL_TOKEN
bunx wrangler secret put CODEROUTER_MASTER_KEY
bunx wrangler secret put MANAGED_ANTHROPIC_API_KEY
bunx wrangler secret put MANAGED_OPENAI_API_KEY
```

The managed provider keys are optional. If a key is absent, managed credentials
for that family cannot be acquired.

## Develop

```bash
bun install
bun run typecheck
bun test
bun run dev
```

`bun run dev` uses `wrangler.dev.toml`, so local work targets
`cmux-coderouter-dev` on workers.dev rather than the production custom domain.
To run wrangler directly:

```bash
bunx wrangler dev --config wrangler.dev.toml
```

## Deploy

Production deploys use `wrangler.toml`, worker name `cmux-coderouter`, and the
custom domain `coderouter.cmux.dev`. Wrangler applies the `[[migrations]]`
block atomically with each upload. Durable Object migrations are append-only:
never edit a past tag; add a new migration tag when the storage class changes.
