# IROH v2 Worker

The Worker owns `/v2/` control routes. Each team and environment maps to one
Durable Object with Drizzle SQLite storage. PlanetScale is used only by the
global EndpointID ownership adapter.

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
`PLANETSCALE_DATABASE_URL` must point at the isolated development database for
that Worker. Do not reuse the production database URL. The script never prints
secret values.
