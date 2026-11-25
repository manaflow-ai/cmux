---
name: cmux-backend
description: "Where cmux Cloud backend code goes (new code: the private manaflow-ai/cmux-platform repo) and the rules for the backend code still in cmux. Use before writing any cloud backend code (control plane, VM API routes and DTOs, provider drivers, billing, entitlements, auth callbacks, the NEXT Worker) and when editing web/app/api, web/services, web/db, backend/apps/api, workers/, Cloud VM lifecycle, Postgres, Stack Auth pricing gates, migrations, or provider image build scripts."
---

# cmux Backend

## Where cloud backend code goes

New cloud backend code goes to the private repository **manaflow-ai/cmux-platform**, not here: the control
plane, VM API routes and their DTOs, provider drivers, metering and billing, entitlements, the hand-off server,
and the NEXT Worker's server logic. It follows that repository's stack: Effect `HttpApi` (contract in `src/api/`,
handlers in `src/server/`), its committed `openapi.json` (`bun run openapi`), and `vp run ci`. Read its README
and open PRs first.

The backend code still in this repository (`web/app/api`, `web/services`, `web/db`, `backend/apps/api`,
`backend/db`, `web/orpc/server`, `workers/cmux-vm`, `workers/device-hub`, `workers/iroh-v2`, `workers/presence`,
`services/iroh-relay-minter`; the list is
`.github/cloud-backend-paths.json`) moves to cmux-platform one PR-sized move at a time: the port lands in
cmux-platform first, then a cmux PR deletes the copy here, and a move changes no behavior. Until a piece has
moved, a fix to it may land here; say so on a line of the PR description that starts `cmux-platform:`. A new
feature on that code moves the code first. `pr-cloud-backend-check` warns on a PR that changes those paths
without that line.

What stays here: the client (the app, `Packages/`, `webviews/`), the CLI (`workers/cmux-vm/cli`,
`workers/cmux-vm/sdk`, the Rust `cmux`), the GUI, and the protocol (`backend/packages/protocol`,
`backend/catalog`).

## Rules for backend code still in this repository

- Default backend TypeScript to Effect under `web/app/api/**`, `web/services/**`, and backend scripts touching providers, databases, auth, rate limits, retries, timeouts, or telemetry.
- Keep Next route handlers thin: parse the request, run one Effect program at the boundary, map typed errors to HTTP responses, treat unexpected defects separately.
- Plain TypeScript is for trivial data shapes, constants, config files, frontend React, and small glue where Effect would add ceremony without improving failure handling.
- Cloud VM backend logic stays in Vercel route handlers and Effect services backed by Postgres. Do not reintroduce Rivet or a raw actor protocol unless a later architecture doc explicitly changes the control plane.
- Postgres is the source of truth for VM lifecycle, active VM limits, idempotency, and usage events.
- Production and staging Cloud VM Postgres use PlanetScale PostgreSQL database `cmux-prod` in organization `cmux`. The runtime reads `DATABASE_URL` with `CMUX_DB_DRIVER=url`; migration jobs use the protected `DATABASE_URL` secret. AWS credentials are not database credentials.
- Run production/staging migrations with `bun run cloud-vm:migrate -- staging` followed by `-- production`; never from Vercel build or route startup. Local `bun dev` uses a `CMUX_PORT`-derived Docker Postgres on Linux; on a Mac, `web/scripts/dev-local.sh` starts no Docker and hands off to the HQ shared-backend helper (`scripts/dev-backend.sh`, not in this repository).
- Cloud VM create pricing gates use Stack Auth team payment items when enabled.

## Secrets

Cloud VM build, test, and local dev scripts read provider secrets from `~/.secrets/cmux.env`: `FREESTYLE_API_KEY` and the other `FREESTYLE_*` vars `web/scripts/build-devbox-freestyle.ts` needs when building the devbox snapshot.

```bash
set -a
source ~/.secrets/cmux.env
set +a
```

`~/.secrets/cmuxterm-dev.env` holds local Stack/web env and not the provider build keys. `bun dev` sources `~/.secrets/cmux.env` first when present, then `~/.secrets/cmuxterm-dev.env`, so cmuxterm-specific Stack settings override broader cmux secrets. The web dev loader still accepts the legacy `~/.secret/cmuxterm.env` and `~/.secrets/cmuxterm.env` paths while machines migrate.

## Detailed references

- [references/effect-boundaries.md](references/effect-boundaries.md): route handlers, services, typed errors, retries, dependency injection.
- [references/cloud-vm-control-plane.md](references/cloud-vm-control-plane.md): VM lifecycle, migrations, Postgres, provider idempotency, pricing gates.
