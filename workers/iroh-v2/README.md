# IROH v2 Worker

The Worker owns `/v2/` control routes. Each team and environment maps to one
Durable Object with Drizzle SQLite storage. The shared ownership adapter uses
the existing production PlanetScale PostgreSQL database. Its only v2 tables are
the global EndpointID ownership map and the corresponding owner counts. Device
registrations, challenges, permissions, directory state and rate limits remain
in Durable Object SQLite. Credentials do not create a row per issuance.

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

The September 15 cutover copied 44 ownership entries from the temporary v2
databases into the existing production database and switched all three Workers
to it. Existing legacy tables were preserved. See the deployment receipt in
`docs/iroh-v2/IMPLEMENTATION.md`. No new database is required.

The ownership adapter sets its five-second statement timeout inside each
transaction because the shared database pool rejects that setting during
connection startup. An opt-in live regression reuses an existing reservation,
checks repeated writes and rejects a conflicting identity without adding rows:
`IROH_V2_OWNERSHIP_SMOKE_DATABASE_URL` selects the database for
`bun test ./live/ownership-database.test.ts`. Supply the URL through a private
environment file. Keep this live check separate from the local workerd suite.
