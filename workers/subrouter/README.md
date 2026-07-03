# cmux-subrouter

Cloudflare Worker + Durable Object control plane for Subrouter.

This is the deployable control-plane scaffold. The Linux data-plane router is
not managed by cmux yet, and the default Freestyle VM image does not bake it
yet. The first value here is CI/CD: PR checks typecheck, test, and dry-run the
Worker bundle; pushes to `main` deploy with Durable Object class migrations
applied atomically by Wrangler.

## Routes

| Route | Method | Purpose |
| --- | --- | --- |
| `/healthz` | `GET` | liveness |
| `/v1/subrouter/capabilities` | `GET` | static support state |
| `/v1/subrouter/status` | `GET` | global Durable Object status |
| `/v1/subrouter/endpoint?url=<url>` | `GET` | normalize Subrouter endpoint URLs |
| `/v1/subrouter/rate-limit-reset-credits` | `GET` | proxy Codex rate-limit reset credits for an account |
| `/v1/subrouter/rate-limit-reset-credits/consume` | `POST` | redeem a Codex rate-limit reset credit |

## Local development

```bash
cd workers/subrouter
bun install
bun run check
bun run dev
```

## Deploy

`.github/workflows/subrouter.yml` mirrors the presence service:

- Pull requests touching `workers/subrouter/**`: `bun run typecheck`, `bun
  test`, and `wrangler deploy --dry-run`.
- Push to `main`: the same checks, then `wrangler deploy` in a serialized
  deployment job.

Required repository secrets are the same as presence:

- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_ID`

No Worker secrets are required for this scaffold. Add secrets only when the
control plane starts mutating per-team router state.
