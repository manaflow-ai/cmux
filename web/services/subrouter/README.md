# Hosted Subrouter

The dashboard and `/api/subrouter/accounts` use the signed-in Stack access
token to exchange a Stack team for a deterministic tenant on `sr.cmux.com`.
The Go service verifies the token and team membership. The web app stores no
tenant keys and needs no Subrouter admin token or database row.

Production defaults to `https://sr.cmux.com`; previews and local development
default to `https://staging.sr.cmux.com`. `SUBROUTER_HOSTED_URL` overrides the
environment default.

The legacy `subrouter_tenants` table remains a recovery and retirement map
until every pre-hosted tenant has moved. Run the migration operator from the
worktree root in three explicit phases:

```sh
bun --cwd web subrouter:migrate-legacy production
bun --cwd web subrouter:migrate-legacy production --apply
bun --cwd web subrouter:migrate-legacy production --apply --finalize-source
```

The first command reads and prints only DB identifiers. `--apply` stages a
credential-safe copy without changing legacy traffic. `--finalize-source`
refreshes and atomically activates the hosted copy, then quiesces the legacy
source. The operator derives destination tenant keys from short-lived Stack
impersonation sessions and revokes each session without logging tokens or keys.

`SUBROUTER_BASE_URL` and `SUBROUTER_ADMIN_TOKEN` remain deployed until the
mapping table is empty. Account deletion retires both mapped legacy tenants and
hosted tenants before removing the Stack user.
