# coderouter

Hosted model router for cmux Cloud VMs and the `cr` CLI. The data plane serves the OpenAI Responses API (`/v1/responses`, `/v1/models`), the Anthropic Messages API (`/v1/messages`, `/v1/messages/count_tokens`, `/v1/models` for Anthropic clients) and the OpenCode provider proxy (`/api/coderouter/opencode/*`), authenticating each request with a route token (`routeTokenAuth.ts`) and forwarding it to one of the team's provider accounts with failover (`codexProxy.ts`, `claudeProxy.ts`, `opencodeProxy.ts`). The control plane under `/api/coderouter/*` manages accounts, sessions and usage.

## Telemetry

PostHog is the primary sink for coderouter traces and errors. Sentry keeps receiving the legacy `coderouter.<failure>` events for existing alert rules and is not extended. Axiom keeps the OpenTelemetry spans at 100% for `/v1/*` and `/api/coderouter/*` (the app-wide sampler treats both as priority subsystems, `services/observability/sampler.ts`).

Every coderouter route runs inside `withCoderouterRoute` (`requestTelemetry.ts`). It owns one request context, one OpenTelemetry route span, and stamps two headers on every response: `x-coderouter-request-id` (the ledger request id, a UUID) and `x-cmux-trace-id` (the Axiom trace). A user who reports a failed request only has to paste the request id. That id is:

- `$ai_trace_id` of the PostHog trace, the `coderouter_request_id` property of every event in it, and `$ai_trace_id` of the `$ai_generation` usage event;
- `request_id` of the ClickHouse `route_events` and `usage_events` rows;
- `cmux.coderouter.request_id` on the Axiom route span (and `trace_id` on the PostHog trace points back at Axiom).

PostHog events go to the main cmux project (`POSTHOG_PROJECT_KEY` / `POSTHOG_HOST`, production or `CODEROUTER_ANALYTICS_FORCE=1`). The distinct id is the Stack user id whenever the request authenticated (the route token's owner, or the signed-in user on control-plane routes), so a person's coderouter requests sit on the same PostHog person as their cmux.com activity. The cmux web app already identifies visitors with the Stack user id (`services/analytics/stackIdentity.ts`); the macOS app still uses an anonymous PostHog id, so joining Mac app events needs a client-side `identify` there (follow-up). Unauthenticated events (auth rejects, alerts) use `coderouter-server` with person processing off. Team and VM ids travel as `team_id` and `coderouter_vm_id`. Until 2026-09-03 these events went to a separate project under HMAC pseudonyms; that project (549394) and its `POSTHOG_CODEROUTER_*` keys are retired, and its dashboards must be rebuilt in the cmux project.

| event | when | key properties |
| --- | --- | --- |
| `$ai_trace` | every request, after the response | `$ai_latency` (s), `$ai_http_status`, `$ai_is_error`, `coderouter_outcome`, `coderouter_failure_stage`, `coderouter_fault`, `coderouter_provider`, `coderouter_agent`, `coderouter_attempts`, `coderouter_vm_id`, `trace_id` |
| `$ai_span` | each step: `auth`, `account_selection`, `credential`, `credential_refresh`, `upstream_attempt`, `provider_config` | `$ai_parent_id` = trace id, `$ai_latency`, `$ai_is_error`, `$ai_error` (failure code), `status`, `attempt`, `upstream_kind` |
| `$ai_generation` | a model response with usage (`analytics.ts`) | tokens, cost estimate, `$ai_latency` to stream end, `$ai_http_status`, `$ai_stream`, `$ai_parent_id` = trace id |
| `$exception` | every failure that is not the caller's fault, and every `reportCoderouterFailure` | `$exception_fingerprint`, `$exception_level`, `$exception_list` with the scrubbed message and, for thrown errors, raw stack frames |
| `coderouter_auth_rejected`, account and session lifecycle, CLI commands | unchanged closed-schema product analytics | now keyed by the Stack user, with `team_id` |

The former `coderouter_route_health` event was folded into `$ai_trace`, which carries every field it had plus the fault class and the request id.

Fault classification (`classifyCoderouterFault`) decides who is paged. `operator` (RDS, KMS, config, an unhandled throw): `$exception` at `error` level. `upstream` (provider 5xx/429 that survived failover, transport timeouts) and `tenant` (no usable account): `warning`. `caller` (bad token, 4xx): trace only, no exception. Fingerprints are `coderouter:<outcome>:<stage>:<provider>` for route outcomes and `coderouter.<failure>:<provider>` for reported failures, so one condition is one PostHog issue.

Unhandled throws in a route are no longer swallowed as a bare 503: the wrapper reports `route_crash` with the real stack (PostHog `$exception`, Sentry), then answers with the surface's own 503 shape.

Upstream model calls are bounded to headers (`upstreamFetch.ts`, `CODEROUTER_UPSTREAM_HEADERS_TIMEOUT_MS`, default 10 minutes). A hung provider fails over to the next account like a connection error instead of holding the function for the full 30 minute `maxDuration`. The body stream is never bounded.

Investigating one failure: take the `x-coderouter-request-id`, open PostHog LLM analytics → Traces and search the id (or filter events by `coderouter_request_id`), read the `$ai_span` waterfall for the failing step, then Error Tracking for the issue. ClickHouse: `SELECT * FROM coderouter.route_events WHERE request_id = '<id>'`. Axiom: `['cmux-prod-otel-traces'] | where ['attributes.custom']['cmux.coderouter.request_id'] == '<id>'`.

## Health

`GET /api/coderouter/health` (`health.ts`) is unauthenticated and value-free. It pings Postgres and ClickHouse with a 4 s bound and checks that the KMS key and region are configured. `200 {"status":"ok"|"degraded"}` when the data plane can route, `503 {"status":"down"}` when Postgres or KMS is missing. Point the uptime monitor at it.

## Alerts

`/api/cron/coderouter-alerts` runs every five minutes (`services/observability/coderouterAlerts.ts`) and posts to the shared Slack webhook `CMUX_ALERTS_SLACK_WEBHOOK_URL` through `sendAlert`. It reads the health probe and the last five minutes of ClickHouse `route_events`:

| key | condition | severity | env |
| --- | --- | --- | --- |
| `coderouter-health` | health is `degraded` or `down` | warning / critical | |
| `coderouter-operator-failures` | `provider_unavailable` from our side (RDS/KMS/config), ≥ 1 | critical | `CMUX_CODEROUTER_ALERT_OPERATOR_FAILURES_5M` |
| `coderouter-upstream-failures` | provider 5xx/transport after failover, ≥ 5 | warning | `CMUX_CODEROUTER_ALERT_UPSTREAM_FAILURES_5M` |
| `coderouter-no-usable-account` | tenants with no healthy account, ≥ 10 (names the teams) | warning | `CMUX_CODEROUTER_ALERT_NO_ACCOUNT_5M` |
| `coderouter-auth-rejected` | unauthorized requests ≥ 25 | warning | `CMUX_CODEROUTER_ALERT_AUTH_REJECTED_5M` |
| `coderouter-ledger-unreachable` | the ClickHouse query itself failed | critical | |

Slack has no dedupe: a persistent condition repeats every run, which is intended for `critical`. With no webhook configured, the cron returns `503 alert_sink_not_configured` until `CMUX_ALERTS_SINK_UNCONFIGURED_ACK` records a plain-text operator decision. After that acknowledgement, triggered alerts are counted as dropped, reported once through `reportCoderouterFailure("alerts")` and as a PostHog `coderouter_alert` event, and the response carries `configured: false`. Production has no webhook as of 2026-09-03; the env audit (`scripts/cloud-vm/projects.mjs`) applies the same waiver.

Why the threshold checks stay in code rather than moving to PostHog insight alerts: PostHog evaluates insight alerts on an hourly or slower cadence and after ingestion lag, while the cron reads the ledger (the source of truth for what was routed) within five minutes, and its thresholds are versioned and tested here. PostHog owns the alert it is good at: an Error Tracking issue alert to Slack when a new `coderouter*` issue appears (configured in the PostHog project, not in code).

## Production checklist

Required env (audited by `bun scripts/cloud-vm/audit-env.mjs production`): `CLICKHOUSE_URL/USER/PASSWORD/DATABASE`, `CODEROUTER_KMS_KEY_ID` + `AWS_REGION`, and `CRON_SECRET`. Configure `CMUX_ALERTS_SLACK_WEBHOOK_URL` unless `CMUX_ALERTS_SINK_UNCONFIGURED_ACK` records the approved unconfigured sink. `POSTHOG_PROJECT_KEY` has an in-code default. The retired `POSTHOG_CODEROUTER_*` and `CODEROUTER_ANALYTICS_SCOPE_SECRET` keys are flagged as legacy by the audit and can be deleted from Vercel.

Before merging a PR with a new `web/db/migrations/*` directory, run `bun run cloud-vm:migrate -- staging` then `-- production`; a merge deploys immediately and the new code selects the new columns first. ClickHouse DDL under `web/db/clickhouse/` is applied with `bun scripts/clickhouse-migrate.ts <db>` for `coderouter_dev` then `coderouter`, also before the merge.
