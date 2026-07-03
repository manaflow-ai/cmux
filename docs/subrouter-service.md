# Subrouter service

Subrouter has two parts:

- **Data plane**: the Linux router/proxy that Codex talks to today through the
  existing `subrouter-team.tail41290.ts.net:31415` path.
- **Control plane**: the cmux-owned service that records support state today
  and can later own per-team router lifecycle, policy, counters, and rollout.

The first cmux-owned control plane lives in `workers/subrouter/`.

## Current support

Supported today:

- Codex/Hermes endpoint preservation in cmux launches.
- `cmux subrouter` and `cmux sr` diagnostics and env/config output for local
  routers and the hosted endpoint at `https://subrouter.cmux.dev`.
- A Cloudflare Worker + Durable Object scaffold for CI/CD and future
  lifecycle control.
- Subrouter control-plane proxy for Codex rate-limit reset credits
  (`/v1/subrouter/rate-limit-reset-credits` and `/consume`), so `cmux sr credits`
  can show which accounts still have a complimentary one-time reset available.

Pending:

- Managed Cloud VM router provisioning.
- Default Freestyle image baking with Subrouter installed.
- cmux-managed data-plane routing.
- Claude/OpenCode routing through Subrouter.

## CI/CD

`workers/subrouter` reuses the same infrastructure pattern as
`workers/presence`:

- PRs run `bun run typecheck`, `bun test`, and `wrangler deploy --dry-run`.
- Pushes to `main` run the same checks, then `wrangler deploy`.
- `wrangler deploy` applies the Durable Object class migrations in
  `wrangler.toml` atomically with the code upload.
- The deploy job is serialized with a `subrouter-deploy` concurrency group.

Required repository secrets are the existing Cloudflare deploy secrets used by
presence:

- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_ID`

No Worker secrets are required for the scaffold. Add Worker secrets only when
the control plane starts mutating team-scoped router state.

## Durable Object model

`SubrouterControl` is a global control object for the first deploy. It returns
the current support status and proves the DO binding, migration, and deploy
path are live without exposing a mutating team-scoped API.

When managed routing lands, add a team-scoped object name derived from the
verified team id, mirroring `workers/presence`:

```text
Stack-authenticated request
  -> Worker verifies team membership
  -> SUBROUTER_CONTROL.idFromName(teamId)
  -> Durable Object owns team router state
```

The DO should own control-plane state only: desired router version, active
Freestyle VM id, health, rollout policy, rate/cost counters, and audit
metadata. It should not proxy model traffic. The data plane stays in the VM or
edge proxy layer.

## Hosted cmux CLI

Use the hosted control plane without setting local environment variables:

```bash
cmux sr doctor --hosted
cmux sr env --hosted --format codex-toml
cmux sr credits --hosted --token "$CODEX_AUTH_TOKEN"
```

`cmux sr credits` defaults to the hosted control plane when neither
`SUBROUTER_CONTROL_PLANE_URL` nor a local Subrouter endpoint is configured.
Pass `--control-plane-url <url>` for local Worker development.
