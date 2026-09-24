# coderouter

Hosted model router for cmux Cloud VMs, the `cr` CLI, and direct API clients. The data plane serves the OpenAI Responses API (`/v1/responses`, `/v1/models`), the Anthropic Messages API (`/v1/messages`, `/v1/messages/count_tokens`, `/v1/models` for Anthropic clients) and the OpenCode provider proxy (`/api/coderouter/opencode/*`). Requests authenticate with a VM or CLI route token, or a long-lived `crk_` API key, then forward to one of the team's provider accounts with failover (`codexProxy.ts`, `claudeProxy.ts`, `opencodeProxy.ts`). The control plane under `/api/coderouter/*` manages accounts, sessions, API keys and usage.

API keys are created through `POST /api/coderouter/api-keys` with a signed-in
team member who has account administration (see "Who can change accounts"),
and the plaintext key is returned once. `GET` lists only safe
metadata. `DELETE /api/coderouter/api-keys/:id` revokes a key, while
`DELETE /api/coderouter/api-keys/self` lets the key holder revoke its own key.
Every model and route ledger row stores the key's opaque UUID, so usage can be
aggregated per key without storing the secret. The `last_used_at` value in the
control plane is display metadata and is written at most once per minute per
key. The ClickHouse usage ledger remains exact for every request.
Failures in this best-effort metadata write are rate-limited operational
events, so a database problem is visible without creating one alert per
request.

API key authentication uses an indexed, read-only hash lookup on the request hot path.
Revocation updates one key row by primary key and does not take a process-wide
lock. PostgreSQL row locks are held only for the affected update. Account
deletion uses one short, team-scoped transaction advisory lock to serialize the
last-account check with concurrent account creation or deletion; it is never
taken by model requests. The auth span records `route_token`, `api_key`, or
`control_plane`. The route and usage ledger rows carry the opaque API-key UUID for joins. No key
secret is logged or sent to telemetry.

## Telemetry

ClickHouse is the source of truth for CodeRouter route outcomes and model usage. PostHog receives only control-plane lifecycle events and operational exceptions. Sentry keeps receiving the legacy `coderouter.<failure>` events for existing alert rules. Axiom keeps the OpenTelemetry spans at 100% for `/v1/*` and `/api/coderouter/*`.

Every coderouter route runs inside `withCoderouterRoute` (`requestTelemetry.ts`). It owns one request context, one OpenTelemetry route span, and stamps two headers on every response: `x-coderouter-request-id` (the ledger request id, a UUID) and `x-cmux-trace-id` (the Axiom trace). A user who reports a failed request only has to paste the request id. That id is:

- `request_id` of the ClickHouse `route_events` and `usage_events` rows;
- `cmux.coderouter.request_id` on the Axiom route span.

PostHog events go to the main cmux project (`POSTHOG_PROJECT_KEY` / `POSTHOG_HOST`, production or `CODEROUTER_ANALYTICS_FORCE=1`). The distinct id is the Stack user id whenever the request authenticated (the route token's owner, or the signed-in user on control-plane routes), so a person's coderouter requests sit on the same PostHog person as their cmux.com activity. The cmux web app already identifies visitors with the Stack user id (`services/analytics/stackIdentity.ts`); the macOS app still uses an anonymous PostHog id, so joining Mac app events needs a client-side `identify` there (follow-up). Unauthenticated events (auth rejects, alerts) use `coderouter-server` with person processing off. Team and VM ids travel as `team_id` and `coderouter_vm_id`. Until 2026-09-03 these events went to a separate project under HMAC pseudonyms; that project (549394) and its `POSTHOG_CODEROUTER_*` keys are retired, and its dashboards must be rebuilt in the cmux project.

| event | when | key properties |
| --- | --- | --- |
| `$exception` | every failure that is not the caller's fault, and every `reportCoderouterFailure` | `$exception_fingerprint`, `$exception_level`, `$exception_list` with the scrubbed message and, for thrown errors, raw stack frames |
| `coderouter_auth_rejected`, account and session lifecycle, CLI commands | unchanged closed-schema product analytics | now keyed by the Stack user, with `team_id` |

Route outcomes, failures, tokens, models, providers, latency, and Cloud VM attribution are stored in ClickHouse `route_events` and `usage_events`. This avoids a second usage ledger in PostHog and keeps billing and product reporting on one authoritative dataset.

Fault classification (`classifyCoderouterFault`) decides who is paged. `operator` (PlanetScale, KMS, config, an unhandled throw): `$exception` at `error` level. `upstream` (provider 5xx/429 that survived failover, transport timeouts) and `tenant` (no usable account): `warning`. `caller` (bad token, 4xx): trace only, no exception. Fingerprints are `coderouter:<outcome>:<stage>:<provider>` for route outcomes and `coderouter.<failure>:<provider>` for reported failures, so one condition is one PostHog issue.

Unhandled throws in a route are no longer swallowed as a bare 503: the wrapper reports `route_crash` with the real stack (PostHog `$exception`, Sentry), then answers with the surface's own 503 shape.

Upstream model calls are bounded to headers (`upstreamFetch.ts`, `CODEROUTER_UPSTREAM_HEADERS_TIMEOUT_MS`, default 10 minutes). A hung provider fails over to the next account like a connection error instead of holding the function for the full 30 minute `maxDuration`. The body stream is never bounded.

Investigating one failure: take the `x-coderouter-request-id`, query ClickHouse `SELECT * FROM coderouter.route_events WHERE request_id = '<id>'`, then use Axiom for the route span and PostHog Error Tracking for the operational issue.

## Health

`GET /api/coderouter/health` (`health.ts`) is unauthenticated and value-free. It pings Postgres and ClickHouse with a 4 s bound and checks that the KMS key and region are configured. `200 {"status":"ok"|"degraded"}` when the data plane can route, `503 {"status":"down"}` when Postgres or KMS is missing. Point the uptime monitor at it.

## Alerts

`/api/cron/coderouter-alerts` runs every five minutes (`services/observability/coderouterAlerts.ts`) and posts to the shared Slack webhook `CMUX_ALERTS_SLACK_WEBHOOK_URL` through `sendAlert`. It reads the health probe and the last five minutes of ClickHouse `route_events`:

| key | condition | severity | env |
| --- | --- | --- | --- |
| `coderouter-health` | health is `degraded` or `down` | warning / critical | |
| `coderouter-operator-failures` | `provider_unavailable` from our side (PlanetScale/KMS/config), ≥ 1 | critical | `CMUX_CODEROUTER_ALERT_OPERATOR_FAILURES_5M` |
| `coderouter-upstream-failures` | provider 5xx/transport after failover, ≥ 5 | warning | `CMUX_CODEROUTER_ALERT_UPSTREAM_FAILURES_5M` |
| `coderouter-no-usable-account` | tenants with no healthy account, ≥ 10 (names the teams) | warning | `CMUX_CODEROUTER_ALERT_NO_ACCOUNT_5M` |
| `coderouter-auth-rejected` | unauthorized requests ≥ 25 | warning | `CMUX_CODEROUTER_ALERT_AUTH_REJECTED_5M` |
| `coderouter-ledger-unreachable` | the ClickHouse query itself failed | critical | |

Slack has no dedupe: a persistent condition repeats every run, which is intended for `critical`. With no webhook configured, the cron returns `503 alert_sink_not_configured` until `CMUX_ALERTS_SINK_UNCONFIGURED_ACK` records a plain-text operator decision. After that acknowledgement, triggered alerts are counted as dropped, reported once through `reportCoderouterFailure("alerts")` and as a PostHog `coderouter_alert` event, and the response carries `configured: false`. Production has no webhook as of 2026-09-03; the env audit (`scripts/cloud-vm/projects.mjs`) applies the same waiver.

Why the threshold checks stay in code rather than moving to PostHog insight alerts: PostHog evaluates insight alerts on an hourly or slower cadence and after ingestion lag, while the cron reads the ledger (the source of truth for what was routed) within five minutes, and its thresholds are versioned and tested here. PostHog owns the alert it is good at: an Error Tracking issue alert to Slack when a new `coderouter*` issue appears (configured in the PostHog project, not in code).

## Production checklist

Required env (audited by `bun scripts/cloud-vm/audit-env.mjs production`): `CLICKHOUSE_URL/USER/PASSWORD/DATABASE`, `CODEROUTER_KMS_KEY_ID` + `AWS_REGION`, and `CRON_SECRET`. Configure `CMUX_ALERTS_SLACK_WEBHOOK_URL` unless `CMUX_ALERTS_SINK_UNCONFIGURED_ACK` records the approved unconfigured sink. `POSTHOG_PROJECT_KEY` has an in-code default. The retired `POSTHOG_CODEROUTER_*` and `CODEROUTER_ANALYTICS_SCOPE_SECRET` keys are flagged as legacy by the audit and can be deleted from Vercel.

Before merging a PR with a new `web/db/migrations/*` directory, run `bun run cloud-vm:migrate -- staging` then `-- production`; a merge deploys immediately and the new code selects the new columns first. ClickHouse DDL under `web/db/clickhouse/` is applied with `bun scripts/clickhouse-migrate.ts <db>` for `coderouter_dev` then `coderouter`, also before the merge.

## VM team and account access

A managed VM has an immutable `cloud_vms.owner_team_id` and one
`coderouter_pool_id` from that same team. `user_id` records its creator;
`billing_team_id` remains billing attribution. Existing machines are backfilled
from their billing scope (or their user id for historical personal machines).
Changing a payer does not reauthorize the VM. Moving ownership is unsupported.

Every VM token lookup checks that its machine still exists, is live, and belongs
to the token's team. The request must also carry the matching edge-injected VM
id. Invalid machine credentials never fall through to a browser cookie or a
caller-selected organization. Account listing, native and Claude routing, and
session reuse apply the same team, visibility, and pool membership predicates.
Removing a pool grant takes effect on the next request, including existing
sessions. An empty pool returns `no_usable_account` rather than routing through
another team or a private account. Requests already sent upstream may finish.

New account API writes explicitly set private visibility and their importing user.
The database default remains shared for compatibility with older servers during
a rolling deployment; old writes must not create ownerless private accounts. Human route tokens and API
keys can use that user's private accounts and the selected team's shared
accounts. An organization VM never inherits its creator's private access.
Private accounts in a personal scope (`team_id = created_by`) are available to
that user's personal VMs. Importing privately into an organization, even a
one-person organization, does not grant its VMs access until the account is
explicitly shared.

The default pool contains that team's shared accounts. Its membership follows
explicit sharing changes. Custom pools have the same composite foreign-key
constraints; custom pool management UI is not part of this change.

`PATCH /api/coderouter/accounts/:id/sharing` accepts
`{"family":"native"|"claude","visibility":"private"|"team"}` with a Stack
session and the selected team. It needs account administration, and a private
account additionally belongs to its importer. The dashboard exposes **Share
with team** and **Make private**. A VM token cannot administer accounts or mint
an organization session. The organization catalog returned to a VM contains
only its own team and `fixed: true`.

### Who can change accounts

Account administration is Stack's `$manage_api_keys` team permission; a
personal scope always has it (`permissions.ts`, `accountAdministration.ts`).
Without it, a team member may still:

- add a private account (`POST /api/coderouter/claude-upstream` and
  `POST /api/coderouter/accounts` without `"visibility":"team"`), which is what
  `cr add claude` and `cr add codex` do by default;
- change or remove a private account they imported.

No other member or machine can use those accounts, so they need no team
permission. Everything else needs account administration: adding a shared
account, changing an account's sharing in either direction, changing or
removing a shared account, removing every account, moving an account between
teams (both teams), and creating or revoking API keys. A member's write runs
under the `own-private` access (`accountAccess.ts`), so the SQL itself cannot
reach another account. A member who re-imports a shared account that is active
gets it back unchanged (`alreadyExists: true`); an inactive one needs an
administrator. A member removing the team's last account does not revoke the
team's route tokens or API keys.

#12771 required the permission for every write, which refused private imports
too (#14111). A VM-bound route token is unchanged: it imports into its team's
shared pool and cannot administer accounts.

A refusal is a `403` whose body names the team and the permission and lists the
ways forward, which `cr` prints:

```json
{
  "error": "forbidden",
  "code": "team_permission_required",
  "message": "You need the $manage_api_keys permission in Acme to share accounts with the team.",
  "teamId": "…",
  "teamName": "Acme",
  "permission": "$manage_api_keys",
  "action": "share_account",
  "options": [
    { "kind": "private", "message": "…", "command": "cr add claude --private" },
    { "kind": "switch_team", "message": "…", "command": "cr org switch <team>" },
    { "kind": "ask_admin", "message": "…" }
  ],
  "retryable": false
}
```

`action` is one of `share_account`, `change_shared_account`,
`remove_all_accounts`, `transfer_account` and `manage_api_keys`. A transfer
refused by the destination team keeps `"error": "destination_forbidden"`.

Inside a managed machine, `cmux coderouter accounts --json` returns native and
Claude account metadata under one team id, and `cmux coderouter org current
--json` reports that fixed team. Organization switching is host-owned. These
restrictions cover cmux's managed credential path; they do not claim to prevent
a shell user from manually supplying independent provider credentials.

The migration preserves existing account visibility by placing existing
accounts in shared default pools. It does not infer that historical imports
were private. Operators can inspect the preserved set without reading secrets:

```sql
SELECT team_id, provider, count(*) AS shared_accounts
FROM coderouter_accounts WHERE visibility = 'team' GROUP BY team_id, provider;
SELECT team_id, kind, count(*) AS shared_accounts
FROM coderouter_claude_accounts WHERE visibility = 'team' GROUP BY team_id, kind;
```

The database tests in `tests/coderouter-vm-scope-db-behavior.test.ts` cover
cross-team grants, spoofed headers, private visibility, pool revocation, and
VM deletion. `scripts/coderouter/verify-vm-scope.ts` exercises the real Freestyle
edge and guest CLI against an isolated development backend using disposable
Stack identities and account metadata. The runner requires
`CMUX_SCOPE_E2E_ENVIRONMENT=isolated-development`, the approved development
Stack project, and matching API/SQL instances on the shared backend host. It verifies account listing and routing
denial after revocation, without importing customer credentials or invoking a
paid upstream model. Route traces include `cmux.coderouter.pool_id`.

The ownership migration is an atomic cutover for small catalogs, with an
explicit precondition of at most 10,000 rows and 32 MiB per existing table.
It aborts before schema changes above either limit. A two-second lock timeout
and fifteen-second statement timeout bound interference with live requests;
a failure rolls back and must be retried. Installations above these limits
require separate online index/backfill phases rather than disabling the guard.
The schema and compatibility triggers must land before deploying new readers.
