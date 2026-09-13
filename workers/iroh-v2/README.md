# IROH v2 Worker

The Worker owns `/v2/` control routes. Each team and environment maps to one
Durable Object with Drizzle SQLite storage. The existing production Postgres
database is used by the global EndpointID ownership adapter.

The shared development Worker is `cmux-iroh-v2-development`. For isolated
branch work, deploy a suffixed Worker:

```sh
./scripts/deploy-dev.sh my-branch
```

The current account uses the `debussy.workers.dev` subdomain.

Put the required secrets in the shell environment or `.dev.vars`. The ownership database URL points at the existing production database. Scope all records by environment, project, team and user. Development Durable Objects remain isolated by Worker environment. The script never prints secret values.
