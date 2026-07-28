# Cloud VM Control Plane

Expands the Cloud VM rules in [../SKILL.md](../SKILL.md).

## Source of truth

Postgres owns VM lifecycle state, active VM limits, idempotency records, usage events, provider identifiers, and team/account ownership. Provider state is observed and reconciled, not treated as canonical. When provider state and database state disagree, make the reconciliation explicit in code.

Cloud VM backend logic lives in Vercel route handlers and Effect services. Request-time workflows must be idempotent; durable state belongs in Postgres. Do not reintroduce Rivet or a raw actor protocol unless a later architecture document explicitly changes this control plane.

## Migrations

Production and staging: `bun db:migrate:aws-rds-iam`. Never run Drizzle migrations from Vercel build or route startup; that makes deploy behavior non-deterministic and couples app availability to schema mutation. Local development keeps the `CMUX_PORT`-derived Docker Postgres path from `bun dev`.

## AWS RDS IAM runtime

Production and staging use the Vercel Marketplace AWS Aurora PostgreSQL OIDC/RDS IAM path with `CMUX_DB_DRIVER=aws-rds-iam`, `AWS_ROLE_ARN`, `AWS_REGION`, `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`. Do not invent parallel env names for the same settings; each new name is another migration and deploy surface.

## Pricing and active limits

Create pricing gates use Stack Auth team payment items when enabled. Active limits and usage events are persisted, not inferred from process memory.

When changing create/start flows, verify that idempotency prevents duplicate provider creates, team ownership is checked before provider allocation, active VM limits are enforced before expensive provider work, usage events are written exactly once per lifecycle moment, and a failed provider call leaves a recoverable database state.
