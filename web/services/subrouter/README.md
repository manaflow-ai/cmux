# Hosted Subrouter

The dashboard and `/api/subrouter/accounts` use the signed-in Stack access
token to exchange a Stack team for a deterministic tenant on `sr.cmux.com`.
The Go service verifies the token and team membership. The trusted web broker
also enforces the team allowlist, Stack permissions, and hosted cutover gate
before it requests a capability-scoped tenant key. Direct client exchange is
rejected. The web app stores no tenant keys and needs no Subrouter admin token
or database row.

Production defaults to `https://sr.cmux.com`; previews and local development
default to `https://staging.sr.cmux.com`. `SUBROUTER_HOSTED_URL` overrides the
environment default.

`/api/cli/config` publishes the same-origin `/api/subrouter/exchange` broker
for native clients. `SUBROUTER_STACK_TENANT_DELETE_TOKEN` authenticates the
web broker to hosted Subrouter for both exchange and tenant retirement.

The legacy `subrouter_tenants` table remains a cutover gate, recovery map, and
retirement map until every pre-hosted tenant has moved. A mapped team cannot
use the hosted control plane until the migration operator verifies its copy
and records `hosted_ready_at`. Run the operator from the worktree root in three
explicit phases:

```sh
bun --cwd web subrouter:migrate-legacy production
bun --cwd web subrouter:migrate-legacy production --apply
bun --cwd web subrouter:migrate-legacy production --apply --finalize-source
```

The first command reads and prints only DB identifiers. `--apply` stages a
credential-safe copy without changing legacy traffic. `--finalize-source`
persists a durable finalization marker, refreshes and atomically activates the
hosted copy, quiesces the legacy source, then opens the hosted gate. Subrouter
v0.1.54 returns its completed receipt for an identical retry, so rerun the same
finalization command after an interrupted gate write. The operator derives
destination tenant keys from short-lived Stack impersonation sessions and
revokes each session without logging tokens or keys.

`SUBROUTER_BASE_URL` and `SUBROUTER_ADMIN_TOKEN` remain deployed until the
mapping table is empty. Account deletion retires both mapped legacy tenants and
hosted tenants before removing the Stack user.
