# IROH v2 Worker

The Worker owns `/v2/` control routes. Each team and environment maps to one
Durable Object with Drizzle SQLite storage. The shared ownership adapter uses
PostgreSQL. PlanetScale PostgreSQL is the recommended v2 target; Aurora remains
the migration source until cutover is complete.

The shared development Worker is `cmux-iroh-v2-development`. For isolated
branch work, deploy a suffixed Worker:

```sh
./scripts/deploy-dev.sh my-branch
```

The current account uses the `debussy.workers.dev` subdomain.

Put the required secrets in the shell environment or `.dev.vars`. Set either
`DATABASE_URL` or `PLANETSCALE_DATABASE_URL`; deployment publishes the chosen
value as the canonical `DATABASE_URL` Worker secret. Scope records by
environment, project, team and user. Development Durable Objects remain
isolated by Worker environment. The script never prints secret values.

For local CLI work, select PlanetScale without changing application code:

```sh
cd web
CMUX_DB_PROVIDER=planetscale bun db:migrate
```

Set `PLANETSCALE_DATABASE_URL` in the environment or a local ignored env file.
`bun db:test` refuses to run against PlanetScale and always uses an isolated
Docker database. The PlanetScale CLI accepts a service token through its secure
credential store or flags; never commit credentials.

Migration is a controlled cutover: export the old Aurora schema/data, apply the
v2 migration on PlanetScale, copy only defined v2 records, verify counts and
EndpointID uniqueness, canary one team, then switch the Worker secret. Keep
Aurora read-only through the rollback window.
