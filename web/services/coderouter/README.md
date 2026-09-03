# coderouter

Hosted model router for cmux Cloud VMs and the `cr` CLI. The data plane serves the OpenAI Responses API (`/v1/responses`, `/v1/models`), the Anthropic Messages API (`/v1/messages`, `/v1/messages/count_tokens`, `/v1/models` for Anthropic clients) and the OpenCode provider proxy (`/api/coderouter/opencode/*`), authenticating each request with a route token (`routeTokenAuth.ts`) and forwarding it to one of the team's provider accounts with failover (`codexProxy.ts`, `claudeProxy.ts`, `opencodeProxy.ts`). The control plane under `/api/coderouter/*` manages accounts, sessions and usage.

## Telemetry

PostHog is the primary sink for coderouter traces and errors. Sentry keeps receiving the legacy `coderouter.<failure>` events for existing alert rules and is not extended. Axiom keeps the OpenTelemetry spans at 100% for `/v1/*` and `/api/coderouter/*` (the app-wide sampler treats both as priority subsystems, `services/observability/sampler.ts`).

Every coderouter route runs inside `withCoderouterRoute` (`requestTelemetry.ts`). It owns one request context, one OpenTelemetry route span, and stamps two headers on every response: `x-coderouter-request-id` (the ledger request id, a UUID) and `x-cmux-trace-id` (the Axiom trace). A user who reports a failed request only has to paste the request id. That id is:

- `$ai_trace_id` of the PostHog trace, the `coderouter_request_id` property of every event in it, and `$ai_trace_id` of the `$ai_generation` usage event;
- `request_id` of the ClickHouse `route_events` and `usage_events` rows;
- `cmux.coderouter.request_id` on the Axiom route span (and `trace_id` on the PostHog trace points back at Axiom).

PostHog events, all in the isolated coderouter project (`POSTHOG_CODEROUTER_PROJECT_KEY`, ingest host `POSTHOG_CODEROUTER_INGEST_HOST`, production or `CODEROUTER_ANALYTICS_FORCE=1`), distinct id = HMAC team scope when the request authenticated, else `coderouter-server`:

| event | when | key properties |
| --- | --- | --- |
| `$ai_trace` | every request, after the response | `$ai_latency` (s), `$ai_http_status`, `$ai_is_error`, `coderouter_outcome`, `coderouter_failure_stage`, `coderouter_fault`, `coderouter_provider`, `coderouter_agent`, `coderouter_attempts`, `coderouter_vm_id`, `trace_id` |
| `$ai_span` | each step: `auth`, `account_selection`, `credential`, `credential_refresh`, `upstream_attempt`, `provider_config` | `$ai_parent_id` = trace id, `$ai_latency`, `$ai_is_error`, `$ai_error` (failure code), `status`, `attempt`, `upstream_kind` |
| `$ai_generation` | a model response with usage (`analytics.ts`) | tokens, cost estimate, `$ai_latency` to stream end, `$ai_http_status`, `$ai_stream`, `$ai_parent_id` = trace id |
| `$exception` | every failure that is not the caller's fault, and every `reportCoderouterFailure` | `$exception_fingerprint`, `$exception_level`, `$exception_list` with the scrubbed message and, for thrown errors, raw stack frames |
| `coderouter_route_health`, `coderouter_auth_rejected`, ... | unchanged bucketed product analytics | now also `coderouter_request_id` |

Fault classification (`classifyCoderouterFault`) decides who is paged. `operator` (RDS, KMS, config, an unhandled throw): `$exception` at `error` level. `upstream` (provider 5xx/429 that survived failover, transport timeouts) and `tenant` (no usable account): `warning`. `caller` (bad token, 4xx): trace only, no exception. Fingerprints are `coderouter:<outcome>:<stage>:<provider>` for route outcomes and `coderouter.<failure>:<provider>` for reported failures, so one condition is one PostHog issue.

Unhandled throws in a route are no longer swallowed as a bare 503: the wrapper reports `route_crash` with the real stack (PostHog `$exception`, Sentry), then answers with the surface's own 503 shape.

Upstream model calls are bounded to headers (`upstreamFetch.ts`, `CODEROUTER_UPSTREAM_HEADERS_TIMEOUT_MS`, default 10 minutes). A hung provider fails over to the next account like a connection error instead of holding the function for the full 30 minute `maxDuration`. The body stream is never bounded.

Investigating one failure: take the `x-coderouter-request-id`, open PostHog LLM analytics → Traces and search the id (or filter events by `coderouter_request_id`), read the `$ai_span` waterfall for the failing step, then Error Tracking for the issue. ClickHouse: `SELECT * FROM coderouter.route_events WHERE request_id = '<id>'`. Axiom: `['cmux-prod-otel-traces'] | where ['attributes.custom']['cmux.coderouter.request_id'] == '<id>'`.

## Health

`GET /api/coderouter/health` (`health.ts`) is unauthenticated and value-free. It pings Postgres and ClickHouse with a 4 s bound and checks that the analytics key pair and the KMS key/region are configured. `200 {"status":"ok"|"degraded"}` when the data plane can route, `503 {"status":"down"}` when Postgres or KMS is missing. Point the uptime monitor at it.

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

Slack has no dedupe: a persistent condition repeats every run, which is intended for `critical`. With no webhook configured the alerts are counted as dropped, reported once through `reportCoderouterFailure("alerts")` and as a PostHog `coderouter_alert` event, and the cron response carries `configured: false`. Production has no webhook as of 2026-09-03; the env audit (`scripts/cloud-vm/projects.mjs`) requires one unless `CMUX_ALERTS_SINK_UNCONFIGURED_ACK` records the decision.

PostHog-side alerting is configured in the PostHog project, not in code: an Error Tracking issue alert to Slack on new `coderouter*` issues, and an insight alert on `$ai_trace` where `coderouter_fault = operator`.

## Production checklist

Required env (audited by `bun scripts/cloud-vm/audit-env.mjs production`): `POSTHOG_CODEROUTER_PROJECT_KEY`, `CODEROUTER_ANALYTICS_SCOPE_SECRET` (≥ 32 bytes), `CLICKHOUSE_URL/USER/PASSWORD/DATABASE`, `CODEROUTER_KMS_KEY_ID` + `AWS_REGION`, `CRON_SECRET`, `CMUX_ALERTS_SLACK_WEBHOOK_URL`. Analytics fail closed without the key pair, so a missing value is a silent observability outage; the health endpoint reports it as `analytics_config`.

Before merging a PR with a new `web/db/migrations/*` directory, run `bun run cloud-vm:migrate -- staging` then `-- production`; a merge deploys immediately and the new code selects the new columns first. ClickHouse DDL under `web/db/clickhouse/` is applied with `bun scripts/clickhouse-migrate.ts <db>` for `coderouter_dev` then `coderouter`, also before the merge.
