# IROH v2 Worker

The Worker owns `/v2/` control routes. Each team and environment maps to one
Durable Object with Drizzle SQLite storage. Ownership and Connected Workspaces
state share the environment's `cmux-prod` PlanetScale branch through the
`HYPERDRIVE_CONNECTED_WORKSPACES` binding. Its only v2 tables are the global
EndpointID ownership map, owner counts, current workspace snapshots, and
workspace event history. Device registrations, challenges, permissions,
directory state and rate limits remain in Durable Object SQLite. Credentials do
not create a row per issuance. The Durable Object is the
team-scoped realtime fan-out layer; it does not become a shared mutable cache.

The shared development Worker is `cmux-iroh-v2-development`. For isolated
branch work, deploy a suffixed Worker:

```sh
./scripts/deploy-dev.sh my-branch
```

The current account uses the `debussy.workers.dev` subdomain.

Put the required secrets in the shell environment or `.dev.vars`. The
production bindings are configured in `wrangler.jsonc`; local tests may use
`DATABASE_URL` or `PLANETSCALE_DATABASE_URL` as a private fixture fallback. The script never
prints secret values.

## Connected Workspaces schema

Apply `ownership-drizzle/0000_endpoint_ownership.sql` to the same branch first.
When moving an existing Worker from a separate ownership database, copy and
verify its ownership and budget rows before switching the binding.

Apply `product-migrations/0000_connected_workspaces.sql` once to each
`cmux-prod` branch (`development`, `staging`, and `main`) through the reviewed
PlanetScale migration path before enabling workspace traffic. The Worker does
not run DDL during a request. The migration stores one current snapshot per
team and VM plus an append-only event history with a unique generation and
revision.

For local CLI work, select PlanetScale without changing application code:

```sh
cd web
CMUX_DB_PROVIDER=planetscale bun db:migrate
```

Set `PLANETSCALE_DATABASE_URL` in the environment or a local ignored env file.
`bun db:test` refuses to run against PlanetScale and always uses an isolated
Docker database. The PlanetScale CLI accepts a service token through its secure
credential store or flags; never commit credentials.

The September 15 cutover copied ownership entries from the temporary v2
databases into the existing production database and switched the Workers to
it. Existing legacy tables were preserved. The ownership adapter sets its
five-second statement timeout inside each transaction because the shared
database pool rejects that setting during connection startup.
