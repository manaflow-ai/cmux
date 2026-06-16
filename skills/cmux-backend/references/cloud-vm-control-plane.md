# Cloud VM Control Plane

This reference expands the Cloud VM rules for lifecycle, persistence, migrations, and provider coordination.

## Source of truth

Postgres is the source of truth for:

- VM lifecycle state
- active VM limits
- idempotency records
- usage events
- provider identifiers
- team/account ownership

Provider state is observed and reconciled, not treated as the canonical application state. If provider state and database state disagree, write code that makes the reconciliation explicit.

## Vercel and Effect boundary

Cloud VM backend logic lives in Vercel route handlers and Effect services. Route handlers should not become a raw actor protocol or long-running in-memory control plane. The durable state belongs in Postgres, and request-time workflows should be idempotent.

Do not reintroduce Rivet or a raw actor protocol unless a later architecture document explicitly changes this control plane.

## Migrations

Production and staging migrations use:

```bash
bun db:migrate:aws-rds-iam
```

Never run Drizzle migrations from Vercel build or route startup. Build/startup migrations make deploy behavior non-deterministic and couple app availability to schema mutation.

Local development keeps using the `CMUX_PORT`-derived Docker Postgres path from `bun dev`.

## AWS RDS IAM runtime

Production and staging Cloud VM Postgres should use the Vercel Marketplace AWS Aurora PostgreSQL OIDC/RDS IAM path with these runtime env names:

- `CMUX_DB_DRIVER=aws-rds-iam`
- `AWS_ROLE_ARN`
- `AWS_REGION`
- `PGHOST`
- `PGPORT`
- `PGUSER`
- `PGDATABASE`

Avoid inventing parallel env names for the same settings. Every new name creates another migration and deploy surface.

## Pricing and active limits

Cloud VM create pricing gates should use Stack Auth team payment items when enabled. Active limits and usage events should be persisted, not inferred from transient process memory.

When changing create/start flows, verify:

- idempotency prevents duplicate provider creates
- team ownership is checked before provider allocation
- active VM limits are enforced before expensive provider work
- usage events are written exactly once for the lifecycle moment they represent
- failed provider calls leave a recoverable database state
