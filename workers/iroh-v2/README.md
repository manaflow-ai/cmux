# IROH v2 Worker

The Worker owns `/v2/` control routes. Each team and environment maps to one
Durable Object with Drizzle SQLite storage. The IROH-specific PlanetScale
database stores endpoint ownership. Connected Workspaces state is stored in the
`cmux-prod` PlanetScale database through the `HYPERDRIVE_CONNECTED_WORKSPACES`
binding.

The two database paths are intentionally separate. `HYPERDRIVE_IROH_OWNERSHIP`
is used only by enrollment ownership checks. `HYPERDRIVE_CONNECTED_WORKSPACES`
is used only by workspace snapshot reads and writes. The Durable Object remains
the team-scoped realtime fan-out layer; it does not make the product database a
shared mutable cache.

The shared development Worker is `cmux-iroh-v2-development`. For isolated
branch work, deploy a suffixed Worker:

```sh
./scripts/deploy-dev.sh my-branch
```

The current account uses the `cmux-presence-worker.workers.dev` subdomain, so
the matching origin is `https://cmux-iroh-v2-dev-my-branch.cmux-presence-worker.workers.dev`.
Set `CMUX_IROH_V2_WORKERS_SUBDOMAIN` when deploying from another Cloudflare
account.

Put the required secrets in the shell environment or `.dev.vars`. The
production bindings are configured in `wrangler.jsonc`; local tests may use
`PLANETSCALE_DATABASE_URL` as a private fixture fallback. The script never
prints secret values.

## Connected Workspaces schema

Apply `product-migrations/0000_connected_workspaces.sql` once to each
`cmux-prod` branch (`development`, `staging`, and `main`) through the reviewed
PlanetScale migration path before enabling workspace traffic. The Worker does
not run DDL during a request. The migration stores one current snapshot per
team and VM plus an append-only event history with a unique generation and
revision.
