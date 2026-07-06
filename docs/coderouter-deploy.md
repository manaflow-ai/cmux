# coderouter — deployment & activation runbook

This is the step-by-step to take coderouter from "code on a branch" to "a cmux
user can route an agent through the gateway and it is metered." It documents the
committed implementation; see `docs/coderouter.md` for architecture.

coderouter has two deployables plus optional app activation:

- **Control plane** — the existing `web/` Next.js app (Vercel + Aurora). Serves
  `/api/coderouter/*`, mints keys, stores credential metadata + encrypted BYOK
  keys, meters usage, and bills.
- **Data plane** — the `workers/coderouter/` Cloudflare Worker + `PoolCoordinator`
  Durable Object at `coderouter.cmux.dev`. Terminates agent traffic and routes it.

## 0. The three shared secrets (read this first)

Three secrets MUST be byte-identical in the worker and the web app. A mismatch
is the most common failure and fails in ways that look unrelated:

| Secret | Used by | Symptom if mismatched |
| --- | --- | --- |
| `CODEROUTER_KEY_SIGNING_SECRET` | web mints `crk_` keys; worker verifies their HMAC | every agent request returns 401 `key auth failed` |
| `CODEROUTER_INTERNAL_TOKEN` | auth for worker↔web internal calls (pool sync, usage ingest, OAuth seed) | pool config never syncs; usage never flushes (401) |
| `CODEROUTER_MASTER_KEY` | web AES-256-GCM-encrypts BYOK keys; worker decrypts | BYOK credentials unusable; managed/oauth unaffected |

Generate once and reuse in both places:

```bash
openssl rand -hex 32   # CODEROUTER_KEY_SIGNING_SECRET (any high-entropy string)
openssl rand -hex 32   # CODEROUTER_INTERNAL_TOKEN     (any high-entropy string)
# CODEROUTER_MASTER_KEY must decode to EXACTLY 32 bytes as base64url (the crypto
# layer uses base64url + rejects anything not 32 bytes). Generate it as base64url:
node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))"
# (shell-only equivalent: openssl rand 32 | openssl base64 -A | tr '+/' '-_' | tr -d '=')
```

## 1. Control plane (`web/`)

### 1a. Run the database migration

The `20260705225705_boring_morlocks` migration creates
`coderouter_pools`, `coderouter_credentials`, `coderouter_keys`, and
`coderouter_usage_events`. Against production Aurora (RDS IAM auth):

```bash
cd web
bun run db:migrate:aws-rds-iam     # scripts/migrate-aws-rds-iam.ts
# local/CI Postgres instead: bun run db:migrate
```

Verify with `bun run db:check` (drizzle reports no drift).

### 1b. Set Vercel environment variables (Production + Preview)

```
CODEROUTER_KEY_SIGNING_SECRET=<shared #1>
CODEROUTER_INTERNAL_TOKEN=<shared #2>
CODEROUTER_MASTER_KEY=<shared #3>
CODEROUTER_WORKER_BASE_URL=https://coderouter.cmux.dev
CMUX_CODEROUTER_CREDIT_ITEM_ID=<optional; managed billing, see §4>
```

All are optional in `web/app/env.ts` so existing deploys keep working; coderouter
is simply inert until they are set.

### 1c. Deploy

Deploy `web/` the normal way (Vercel). Confirm the routes exist:

```bash
curl -sS https://cmux.com/api/coderouter/usage -H "Authorization: Bearer <stack-access>" \
     -H "X-Stack-Refresh-Token: <stack-refresh>" -H "X-Cmux-Team-Id: <team>"
```

The macOS app already resolves the control plane as `AuthEnvironment.coderouterBaseURL`
(prod `https://cmux.com`, DEBUG `http://localhost:$CMUX_PORT`).

## 2. Data plane (`workers/coderouter/`)

### 2a. Provision Worker secrets (NOT `[vars]`)

```bash
cd workers/coderouter
bunx wrangler secret put CODEROUTER_KEY_SIGNING_SECRET   # shared #1
bunx wrangler secret put CODEROUTER_INTERNAL_TOKEN       # shared #2
bunx wrangler secret put CODEROUTER_MASTER_KEY           # shared #3
bunx wrangler secret put MANAGED_ANTHROPIC_API_KEY       # optional, §4
bunx wrangler secret put MANAGED_OPENAI_API_KEY          # optional, §4
```

`CONTROL_PLANE_BASE_URL=https://cmux.com` is already in `wrangler.toml` `[vars]`.

### 2b. Deploy

Either manually:

```bash
bunx wrangler deploy
```

…or push to `main` and let `.github/workflows/coderouter.yml` deploy it (requires
repo secrets `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` — the presence
worker already uses these). The deploy provisions the `coderouter.cmux.dev`
custom domain on the cmux.dev zone and applies the DO `v1` migration atomically.

### 2c. Smoke test

```bash
curl -sS https://coderouter.cmux.dev/healthz      # -> 200 ok
curl -sS https://coderouter.cmux.dev/v1/models    # -> model catalog JSON
```

## 3. Backend-only end-to-end proof (no app required)

This exercises the whole data path. You need a Stack access+refresh token for a
signed-in user and their team id.

```bash
AUTH=(-H "Authorization: Bearer $STACK_ACCESS" -H "X-Stack-Refresh-Token: $STACK_REFRESH" -H "X-Cmux-Team-Id: $TEAM")

# 1) Mint a caller key (returned once)
KEY=$(curl -sS "${AUTH[@]}" -H 'content-type: application/json' \
  -d '{"name":"proof"}' https://cmux.com/api/coderouter/keys | jq -r .key)

# 2) Add a BYOK Anthropic key to the pool
curl -sS "${AUTH[@]}" -H 'content-type: application/json' \
  -d '{"family":"anthropic","label":"my key","apiKey":"sk-ant-..."}' \
  https://cmux.com/api/coderouter/credentials

# 3) Call the gateway with the crk key — routed to the BYOK credential
curl -sS https://coderouter.cmux.dev/anthropic/v1/messages \
  -H "Authorization: Bearer $KEY" -H 'content-type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"claude-sonnet-4-5","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}'

# 4) Confirm a usage row landed
curl -sS "${AUTH[@]}" 'https://cmux.com/api/coderouter/usage?days=1'
```

If step 3 returns a completion and step 4 shows tokens, the full pool → select →
inject → upstream → meter path works.

## 4. Optional — managed/resale tier

To let teams pay cmux and use models with no credentials of their own:

1. Create a Stack Auth "item" representing coderouter credits (micro-USD units).
2. Set `CMUX_CODEROUTER_CREDIT_ITEM_ID` (web) to that item id.
3. Set `MANAGED_ANTHROPIC_API_KEY` / `MANAGED_OPENAI_API_KEY` (worker secrets).
4. Grant credits to a team (increase the Stack item quantity).

Without these, managed is disabled and returns `insufficient_credits`; BYOK and
subscription-OAuth credentials still route normally.

## 5. Activate in the macOS app

Once the backend is live, in a signed-in cmux build: **Settings → AI Gateway →
Create gateway key**, then enable **Route Claude Code through the gateway**. New
Claude Code launches get `ANTHROPIC_BASE_URL=https://coderouter.cmux.dev/anthropic`
+ `ANTHROPIC_AUTH_TOKEN=<crk key>` injected (Codex/OpenAI injection is Phase 3).

The pool still needs at least one credential (BYOK key or connected subscription).
Today those are added via the API (§3); the in-app add/connect UI is Phase 3.

### Phase 3 (app code still to build)

1. In-app "Add API key (BYOK)" form → `POST /api/coderouter/credentials`.
2. In-app "Connect subscription" OAuth screens — OpenAI device-code + Anthropic
   PKCE paste (control-plane routes exist; app client methods + UI do not).
3. Codex/OpenAI launch injection (Phase 2 spawn merge is Claude-only).
4. Usage display in the AI Gateway section → `GET /api/coderouter/usage`.

## 6. Caveats

- **Nothing has been exercised against live providers yet** — all tests are
  unit-level. The first real deploy is where OAuth-refresh response shapes, the
  `chatgpt.com/backend-api/wham/usage` and `api.anthropic.com/api/oauth/usage`
  shapes, and provider header quirks get validated. Budget a debugging pass.
- Keep the three shared secrets in a secret manager; rotating `CODEROUTER_MASTER_KEY`
  invalidates every stored BYOK key (they must be re-added).
- Dev override: point a local app/agent at a dev worker with
  `CMUX_CODEROUTER_GATEWAY_BASE_URL` and the control plane with
  `CMUX_CODEROUTER_BASE_URL`.
