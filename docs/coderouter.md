# coderouter

coderouter is the cmux LLM gateway. It has a Cloudflare Worker data plane in
`workers/coderouter/` and an API-only control plane in `web/app/api/coderouter/`
backed by services in `web/services/coderouter/`.

The Worker terminates caller keys, selects a team credential through a
per-team Durable Object, forwards the request to the native upstream protocol,
streams the response back, and reports usage. The web control plane mints
caller keys, stores credential metadata, starts connect flows, syncs pool
configuration to the Worker, ingests usage, and debits managed credits.

## Architecture

```
Coding agent
  |
  | Authorization: Bearer crk_... or x-api-key: crk_...
  v
Cloudflare Worker: cmux-coderouter
  - /healthz and /v1/models are public
  - /anthropic/*, /openai/v1/*, /codex/* require a crk_ key
  - /internal/* requires CODEROUTER_INTERNAL_TOKEN
  |
  | idFromName("<teamId>:<family>")
  v
PoolCoordinator Durable Object
  - synced key list and credential metadata
  - OAuth token chains
  - sticky conversation assignments
  - rate-limit and cooldown state
  - buffered usage and status updates
  |
  +--> native upstream API
  |
  +--> web /api/coderouter/internal/usage-ingest

web /api/coderouter/*
  - authenticated key, credential, connect, and usage APIs
  - service-token pool-config and usage-ingest APIs
  - Postgres tables: coderouter_pools, coderouter_credentials,
    coderouter_keys, coderouter_usage_events
```

One Durable Object owns one `teamId:family` pool. On a control-plane mutation,
web builds a full `PoolConfig` and posts it to
`/internal/pools/:poolId/sync`. If the DO has no config on first acquire, it
lazy-pulls `/api/coderouter/internal/pool-config?poolId=...` from the web
control plane. If that pull fails and no stored config exists, acquire returns
`config_unavailable`, mapped to `503` with `retry-after: 5`.

## Endpoints

| Client base URL | Upstream rewrite | Family | Allowed credential classes |
| --- | --- | --- | --- |
| `https://coderouter.cmux.dev/anthropic` | strip `/anthropic`; forward path and query to `https://api.anthropic.com` | `anthropic` | `oauth`, `byok`, `managed` |
| `https://coderouter.cmux.dev/openai/v1` | rewrite as `/v1/*` on `https://api.openai.com` | `openai` | `byok`, `managed` |
| `https://coderouter.cmux.dev/codex` | rewrite as `/backend-api/codex/*` on `https://chatgpt.com` | `openai` | `oauth` |

Public Worker routes:

- `GET /healthz`: returns service liveness.
- `GET /v1/models`: returns the Worker pricing catalog model ids.

Internal Worker routes:

- `POST /internal/pools/:poolId/sync`: stores a full `PoolConfig`.
- `POST /internal/pools/:poolId/seed-oauth`: stores an OAuth chain in the DO.

Public web control-plane routes, all authenticated with the existing VM auth
helpers and team resolution:

- `GET|POST|DELETE /api/coderouter/keys`
- `GET|POST|DELETE /api/coderouter/credentials`
- `POST /api/coderouter/credentials/import`
- `POST /api/coderouter/connect/anthropic`
- `POST /api/coderouter/connect/openai`
- `GET /api/coderouter/usage`

Internal web routes require `Authorization: Bearer $CODEROUTER_INTERNAL_TOKEN`:

- `GET /api/coderouter/internal/pool-config?poolId=<teamId>:<family>`
- `POST /api/coderouter/internal/usage-ingest`

## Caller Keys

Caller keys use the `crk_` format implemented in both
`workers/coderouter/src/keys.ts` and `web/services/coderouter/keys.ts`:

```
crk_<base64url(payloadJSON)>.<base64url(hmac)>
```

The payload is `{"v":1,"kid":"<uuid>","team":"<teamId>","iat":<unix seconds>}`.
The HMAC signs the `crk_<payload>` prefix with
`CODEROUTER_KEY_SIGNING_SECRET`. Web stores only `sha256(fullKey)` in
`coderouter_keys.secret_hash` and returns the full key exactly once from
`POST /api/coderouter/keys`.

The Worker verifies the HMAC statelessly and then asks the DO to verify that
the `kid` is present, not revoked, and allowed by key policy.

## Credential Classes

- `oauth`: team-owned subscription accounts. The DO stores OAuth token chains
  in SQLite and refreshes access tokens before use. Postgres stores only
  metadata such as label, provider email, account id, and status.
- `byok`: team-owned provider API keys. Web encrypts the secret as
  `crv1:<iv>:<ciphertext-with-tag>` using AES-256-GCM with
  `CODEROUTER_MASTER_KEY`; the encrypted envelope is synced to the DO.
- `managed`: cmux-owned provider keys stored as Worker secrets. Managed
  acquire requires managed billing to be enabled, a positive balance snapshot,
  and a priced model.

Selection is implemented in `workers/coderouter/src/select.ts` and
`src/acquirePolicy.ts`. Sticky conversation assignments are reused while the
assigned credential remains healthy. New selection prefers usable `oauth`,
then `byok`, then `managed`, then lower-headroom `oauth`; cooling-down
credentials are never selected, and headroom-exhausted `oauth` is used only
when nothing else remains.

The Worker strips caller auth, hop-by-hop headers, `chatgpt-account-id`, and
all `x-coderouter-*` request headers before forwarding. It injects only the
selected credential's upstream auth headers and returns
`x-coderouter-credential: <class>` to the client.

## Environment

Worker plain vars in `workers/coderouter/wrangler.toml`:

- `CONTROL_PLANE_BASE_URL`: production is `https://cmux.com`.

Worker secrets, set once with `wrangler secret put`:

```bash
cd workers/coderouter
bunx wrangler secret put CODEROUTER_KEY_SIGNING_SECRET
bunx wrangler secret put CODEROUTER_INTERNAL_TOKEN
bunx wrangler secret put CODEROUTER_MASTER_KEY
bunx wrangler secret put MANAGED_ANTHROPIC_API_KEY
bunx wrangler secret put MANAGED_OPENAI_API_KEY
```

`MANAGED_ANTHROPIC_API_KEY` and `MANAGED_OPENAI_API_KEY` are optional. Without
one of them, managed credentials for that family cannot be acquired.

Web env in `web/app/env.ts` and `web/.env.example`:

- `CODEROUTER_KEY_SIGNING_SECRET`
- `CODEROUTER_INTERNAL_TOKEN`
- `CODEROUTER_MASTER_KEY`
- `CODEROUTER_WORKER_BASE_URL`
- `CMUX_CODEROUTER_CREDIT_ITEM_ID`

When `CMUX_CODEROUTER_CREDIT_ITEM_ID` is unset, managed billing is disabled
and balance reads as zero. When `CODEROUTER_WORKER_BASE_URL` or the internal
token is missing, mutations that need Worker sync return a configuration
error instead of silently claiming the sync happened.

## Client Wiring

Claude Code:

```bash
export ANTHROPIC_BASE_URL="https://coderouter.cmux.dev/anthropic"
export ANTHROPIC_AUTH_TOKEN="crk_..."
```

Codex config:

```toml
chatgpt_base_url = "https://coderouter.cmux.dev/codex"
openai_base_url = "https://coderouter.cmux.dev/openai/v1"
api_key = "crk_..."
```

The same caller key can be sent as `Authorization: Bearer crk_...` or as
`x-api-key: crk_...`.

## Connect Flows

Anthropic paste-code flow:

1. Call `POST /api/coderouter/connect/anthropic` with `{"action":"start"}`.
2. The API returns an `authorizeUrl` and `state`, and sets an HttpOnly state
   cookie scoped to the connect route.
3. Complete the provider authorization and paste back the resulting
   `code#state` value with `{"action":"complete","code":"..."}`.
4. Web exchanges the code, creates an `oauth` credential row with metadata
   only, seeds the OAuth chain into the DO, and syncs the family pool.

OpenAI device flow:

1. Call `POST /api/coderouter/connect/openai` with `{"action":"start"}`.
2. The API returns `deviceCode`, `userCode`, `verificationUri`, and optional
   timing fields.
3. Poll with `{"action":"poll","deviceCode":"..."}` until the response is
   `{"status":"complete","credential":...}` or remains pending.
4. If the provider rejects the device-flow shape, the API returns
   `connect_unsupported`; use import instead.

OAuth import:

```http
POST /api/coderouter/credentials/import
```

Body:

```json
{
  "provider": "openai",
  "accessToken": "...",
  "refreshToken": "...",
  "idToken": "...",
  "accountId": "...",
  "email": "user@example.com",
  "expiresAt": 1783212345000,
  "label": "Dedicated coding account"
}
```

Import is always available. After import, coderouter owns the refresh chain;
provider refresh rotation can invalidate the local copy.

## Usage And Billing

The Worker extracts usage from JSON responses and from SSE streams without
accumulating full stream text. It reports a usage event to the DO with token
counts, status, latency, credential class, endpoint class, model, and whether
the usage was estimated.

The DO buffers events in SQLite and flushes batches of up to 500 to
`/api/coderouter/internal/usage-ingest`. Web inserts by `eventId` with
`onConflictDoNothing`, re-prices managed events with the authoritative web
catalog in `web/services/coderouter/pricing.ts`, debits the Stack item
configured by `CMUX_CODEROUTER_CREDIT_ITEM_ID`, and returns the current
`balanceMicros` snapshot to the DO.

Pricing values are integer micro-USD per token. Each component is rounded up:

```
ceil(tokens * microsPer1M / 1_000_000)
```

Unknown models are allowed for `oauth` and `byok`; managed acquire fails with
`model_not_priced`.

## CI/CD

`.github/workflows/coderouter.yml` is path-filtered to `workers/coderouter/**`
and the workflow file. PRs run:

```bash
cd workers/coderouter
bun install --frozen-lockfile
bun run typecheck
bun test
bunx wrangler deploy --dry-run --outdir dist
```

Pushes to `main` run the same test job and then deploy with
`bunx wrangler deploy`, serialized by the `coderouter-deploy` concurrency
group. Deploy requires repository secrets `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID`. Worker runtime secrets are not stored in the workflow;
they are set with `wrangler secret put` and survive deploys.
