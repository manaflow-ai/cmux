# Live model catalog and the model scout

The model list every cmux client shows comes from one service we control: cloud-api's
`GET /v1/models/catalog` (production `https://cloud-api.cmux.dev`, staging
`https://cloud-api-staging.cmux.dev`). acpmux fetches it, caches it on disk and keeps working
offline with its last good copy (and the bundled snapshot before the first fetch).

## What it serves

- Every harness (Claude Code, Codex, Gemini CLI, the AI Gateway, the probe harnesses) with its
  models, efforts, families and defaults: models.dev projected through
  `web/services/model-catalog/overrides.ts` (schemaVersion 1, `web/services/model-catalog/types.ts`).
- The `cmux` harness: the cmux Pro model router's own models, built from the deployment's
  `INFERENCE_MODEL_ALLOWLIST` and `backend/apps/api/src/inference/catalog.ts` (price, context,
  tools), with the plans that may use them.
- `version` (a number per publish), a strong `ETag` (clients send `If-None-Match` and get 304),
  `Cache-Control: public, max-age=300, stale-while-revalidate=86400`.
- 503 `catalog.unpublished` before the first publish: clients keep their cached copy.

Code: `backend/apps/api/src/models-catalog/` (ModelCatalogDO keeps the last 50 versions, the
kills and the last 500 scout runs).

## Turn a model off (kill switch)

A kill marks the model `status: "disabled"` (with `statusReason`) in every served version, moves a
harness default off it, and makes the router refuse it with 403 `model.disabled` before any
upstream call; `/v1/inference/models` hides it. A kill outlives later publishes. It takes effect
within about 30 s (each Worker isolate re-reads the kills every 30 s); clients see it on their next
catalog fetch (5 min, sooner on a restart).

The admin token is `MODELS_CATALOG_TOKEN` in `~/.secrets/cmux-next-api-<env>.env` (a Worker
secret on each deployment):

```sh
K=$(grep '^MODELS_CATALOG_TOKEN=' ~/.secrets/cmux-next-api-production.env | cut -d= -f2-)
# every harness ("harness" defaults to "*"); or {"model": "claude-opus-5-5", "harness": "claude", ...}
curl -X POST https://cloud-api.cmux.dev/internal/v1/models/kill -H "authorization: Bearer $K" \
  -H 'content-type: application/json' -d '{"model":"google/gemini-4-neon","reason":"provider outage"}'
curl -X POST https://cloud-api.cmux.dev/internal/v1/models/unkill -H "authorization: Bearer $K" \
  -H 'content-type: application/json' -d '{"model":"google/gemini-4-neon"}'
curl https://cloud-api.cmux.dev/internal/v1/models/status -H "authorization: Bearer $K"   # versions, kills, runs
```

To roll back a bad publish, PUT an older body again (`/internal/v1/models/status` lists the
versions; the scout's next run publishes the current projection again).

## The model scout (automation `models-scout`)

`scripts/models/scout.ts`, run every 6 h by the cmux automation `models-scout`
(`scripts/models/run-scout.sh`). It runs where no Mac must be awake: on the team Cloud machine
"Cloud Machine 2" (since 2026-11-20; the Mac's launchd copy is deleted, so one copy runs), from a
checkout the runner moves to the newest `feat-cmux-next` before each run. The first run on a machine
clones the repo (about 1.1 GB, several minutes) detached from the start step, so it fits in the run's
timeout; later runs only fetch. Make it with a CLI from nightly 4487759453601 or later (it has c8b0ee73,
the detached clone). Its steps run at most 100 s (3a27f805); since cmux-vm sends a long exec as a
provider background request, steps of up to 290 s pass too (the provider's edge had cut an exec held
open at about 125 s, "the machine did not answer"). Proved 2026-11-21 by run
run_6095baeb0a9532d05c31: a fresh clone, then the scout, in 216 s:

```sh
cmux automation create models-scout --command 'bash scripts/models/run-scout.sh' \
  --repo manaflow-ai/cmux --ref feat-cmux-next --every 6h --timeout 20m --catch-up latest \
  --target cloud --machine 'Cloud Machine 2'   # --machine: needed when the team has 2+ machines (a CLI with 1603df5c)
# each secret from a hidden prompt or stdin, never an argument:
cmux automation secret set models-scout MODELS_CATALOG_TOKEN_STAGING --target cloud
```

Its secrets (environment variables; on a Mac, `~/.secrets` files instead): `MODELS_CATALOG_TOKEN_STAGING`,
`MODELS_CATALOG_TOKEN_PRODUCTION` (publish, run reports), `CMUX_E2E_EMAIL`, `CMUX_E2E_PASSWORD`,
`CMUX_STACK_PUBLISHABLE_KEY` (the production e2e account, router smoke), `VERTEX_RELAY_KEY` (the
production console's Vertex relay, `INFERENCE_VERCEL_RELAY_KEY` of production: smoke turns on Vertex
with no Google key), `GH_TOKEN` (push a branch and open a draft PR in manaflow-ai/cmux). With a gcloud
login (a Mac) the Vertex model list is Vertex's own; on a Cloud machine it is models.dev's
`google-vertex` list, and the smoke turn says whether our Vertex serves the model. A failed run (exit 3
or 1, or a timeout) posts a Feed notice to the automation's creator. One run:

1. projects models.dev through the overrides and publishes it to staging, then production, only
   when its content changed (a model a harness's overrides admit appears with no human step);
2. smoke-tests every router model on production with a real tool-call turn (the e2e account);
3. lists Google's models on our Vertex AI (project cmux-489202); a chat model new since the last
   run gets a tool-call smoke turn there, through the console's relay. Pass: a draft PR adds it to the router on staging (a
   human decides the price and production). Fail: a cmux notification "New model not served" and
   a failed run;
4. reports the run to cloud-api; exits 3 when anything failed (the automation runner then shows
   and notifies it).

Watch it:

- `cmux automation history models-scout --target cloud`, `cmux automation logs <run> --target cloud`,
  the Automations page;
- `GET /v1/models/catalog/health` (public): last run, what it added, what failed; 503 when no good
  run landed in 13 hours (uptime checks can poll it);
- by hand: `bun scripts/models/scout.ts --dry-run` (no publish, no PR, no state written).

State (Vertex models seen, PRs opened): `~/.local/state/cmux/models-scout/state.json`.

## Gemini on cmux Pro (our Vertex AI)

The router reaches Vertex through the console's keyless relay
(`backend/apps/dashboard/src/lib/vertex-relay.ts`): Vercel OIDC token, then Workload Identity
Federation (pool `vercel-manaflow`, provider `vercel-dashboard`, production tokens of the two
dashboard projects only), then the service account `cmux-model-router` (roles/aiplatform.user).
No Google key exists. Gemini 4 models are served from the `global` location only. Calls carry the
labels `cmux_service=model-router` and `cmux_env`; the router caps Vertex spend per day
(`INFERENCE_DAILY_CAP_USD_VERTEX`: 5 USD staging, 25 USD production).
