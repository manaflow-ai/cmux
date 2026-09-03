# Cloud VM and CodeRouter product analytics (PostHog)

Project: the main cmux project (`244066`), the same project as desktop
`cmux_daily_active`, signed-in web, iOS and Stripe billing events.

Dashboard: **Cloud VMs + CodeRouter (product)**, built and refreshed by
`scripts/posthog-cloud-dashboard.py` in cmuxterm-hq. The daily analytics email
(`scripts/analytics-report.py`) reads the same query catalog
(`scripts/posthog_cloud_metrics.py`) and links to the dashboard.

Everything here is emitted by the web server only. No CLI or Swift client
sends any of these events.

## Identity model

| Concept | Value |
| --- | --- |
| `distinct_id` | Stack user id (person). Same id as web `$identify`, iOS and `cmux_billing_*`. |
| `$groups.stack_team` | Stack billing team id (group type `stack_team`, already used by team billing events). |
| person `$set` | `billing_plan` (`free`, `pro`, `team`, `founders`) from the plan that authorized the machine. |
| person `$set_once` | `cloud_vm_first_created_at`, `cloud_vm_first_attached_at`, `coderouter_first_generation_at`, `coderouter_first_account_added_at`, `coderouter_first_session_at`. |
| `$lib` | `cmux-web-server` on every event from `services/analytics/serverEvents.ts`. |

Events carry `$geoip_disable: true` (the IP is Vercel's) and an `$insert_id`.
Machine create and destroy use `cloud_vm_created:<vm id>` and
`cloud_vm_destroyed:<vm id>` so a retried request cannot double count.

## Cloud VM events

Source: the `cloud_vm_usage_events` ledger. Every workflow writes one ledger
row per lifecycle fact, from every path (route, status-reconcile cron, account
deletion). `services/vms/productAnalytics.ts` decorates the repository and
mirrors the allowlisted rows below, so PostHog and the billing ledger agree by
construction. Failures are not mirrored; `cloud_vm_request` and
`cloud_vm_provision` own them.

Common properties: `product: cloud_vm`, `ledger_event`, `vm_id`
(`cloud_vms.id` UUID, the id CodeRouter events also carry), `provider`,
`image_id`, `plan_id`, `billing_team_id`, `schema_version: 1`.

| Event | Ledger row | Extra properties |
| --- | --- | --- |
| `cloud_vm_created` | `vm.created` | `origin` (`create`, `restore`, `fork`, `base`), `image_version`, `image_size`, `memory_mb`, `persistent_home`, `per_machine_home`, `idempotency_key_set` |
| `cloud_vm_destroyed` | `vm.destroyed` | `reason` (`user_request`, `account_deletion`, `provider_status_cron`, `provider_status_refresh`, `base_open_provider_missing`), `lifetime_seconds`, `home_volume_deleted` |
| `cloud_vm_attached` | `vm.attach` | `transport`, `invited` |
| `cloud_vm_exec` | `vm.exec` | `exit_code`, `command_length` |
| `cloud_vm_forked` | `vm.forked` | `native`, `idempotency_key_set` (emitted for the source machine; the fork itself is a `cloud_vm_created` with `origin: fork`) |
| `cloud_vm_resumed` | `vm.resumed` | `source` |
| `cloud_vm_snapshot_created` | `vm.snapshot.created` | `named` |
| `cloud_vm_port_opened` | `vm.open_port` | `port` |
| `cloud_vm_base_opened` | `vm.base.opened` | `generation` |
| `cloud_vm_base_reset` | `vm.base.reset` | `generation` |

Request telemetry (`cloud_vm_request`, schema 2, and `cloud_vm_provision`,
schema 3) now also carries `vm_id` (the provider vm id from the URL),
`plan_id`, `billing_customer_type`, `billing_team_id` and the `stack_team`
group, so paywall and limit failures (`vm_requires_pro`,
`vm_active_limit_exceeded`, `vm_access_requires_pro`,
`vm_create_credits_insufficient`) break down by plan and join to billing.
`approve_cmux_remote_enrollment` is a polled operation as of schema 2: its
successes no longer produce rows (they were 17.8k of 22k rows in one week).

## CodeRouter events

Source: the routed request path in `services/coderouter/{codex,claude,opencode}Proxy.ts`
and the account, session and upstream routes, through
`services/coderouter/productAnalytics.ts`.

| Event | When | Properties |
| --- | --- | --- |
| `$ai_generation` | one per successful completion with usage | `product: coderouter`, `$ai_provider` (`openai`, `anthropic`, `opencode`), `$ai_model` (sanitized id), `model_family`, `$ai_input_tokens`, `$ai_cache_read_input_tokens`, `$ai_output_tokens`, `total_tokens`, `$ai_total_cost_usd` and `api_equivalent_usd`, `priced_tokens`, `unpriced_tokens`, `pricing_version`, `$ai_http_status`, `$ai_is_error: false`, `route_provider`, `agent`, `vm_bound`, `vm_id`, `upstream_kind` |
| `coderouter_request_failed` | one per failed routed request with a known identity | `route_provider`, `agent`, `outcome`, `failure_stage`, `status`, `duration_ms`, `attempt_count`, `vm_bound`, `vm_id`, `upstream_kind` |
| `coderouter_account_added` | provider account stored | `provider`, `source` (`native_api`, `legacy_dashboard`), `already_exists` |
| `coderouter_account_removed` | provider account removed | `source`, `last_account` |
| `coderouter_route_session_issued` | `cr login` or VM token minted | |
| `coderouter_claude_upstream_set` / `_removed` | Claude upstream configured | `upstream_kind`, `replaced` |

`$ai_total_cost_usd` is the API-equivalent list-price estimate of the tokens
routed (rate card `pricing_version`), not money cmux spent: upstream accounts
are the user's own subscriptions. Label it as an estimate everywhere it is
shown.

The OpenCode proxy does not parse usage, so it produces failures only.

### Relationship to the isolated CodeRouter project

`services/coderouter/analytics.ts` keeps sending operations telemetry to the
isolated project (`549394`) with HMAC pseudonyms and no person profiles. That
project cannot answer any per-user question by design, and customer-facing
usage moved to the ClickHouse ledger, so the isolated project is now only an
operations view. Retiring it is a separate decision; until then CodeRouter
traffic is captured twice.

## Query shapes

Cloud active user on a day: any `cloud_vm_*` lifecycle event.

```sql
SELECT toStartOfDay(timestamp) AS d, count(DISTINCT distinct_id) AS users
FROM events
WHERE event IN ('cloud_vm_created','cloud_vm_attached','cloud_vm_exec','cloud_vm_forked',
                'cloud_vm_resumed','cloud_vm_snapshot_created','cloud_vm_port_opened',
                'cloud_vm_base_opened','cloud_vm_base_reset')
  AND timestamp >= now() - INTERVAL 30 DAY
GROUP BY d ORDER BY d
```

Paywall to checkout funnel (users who hit a limit, then started and completed
checkout within 7 days):

```sql
WITH hits AS (
  SELECT distinct_id, min(timestamp) AS hit_at FROM events
  WHERE event = 'cloud_vm_request' AND properties.success = false
    AND properties.error_code IN ('vm_requires_pro','vm_active_limit_exceeded',
                                  'vm_access_requires_pro','vm_create_credits_insufficient')
    AND timestamp >= now() - INTERVAL 30 DAY
  GROUP BY distinct_id)
SELECT count() AS hit,
       countIf(started_at IS NOT NULL) AS started,
       countIf(completed_at IS NOT NULL) AS completed
FROM hits
LEFT JOIN (SELECT distinct_id, min(timestamp) AS started_at FROM events
           WHERE event = 'cmux_billing_checkout_started' GROUP BY distinct_id) s USING distinct_id
LEFT JOIN (SELECT distinct_id, min(timestamp) AS completed_at FROM events
           WHERE event = 'cmux_billing_checkout_completed' GROUP BY distinct_id) c USING distinct_id
WHERE (started_at IS NULL OR (started_at >= hit_at AND started_at <= hit_at + INTERVAL 7 DAY))
  AND (completed_at IS NULL OR (completed_at >= hit_at AND completed_at <= hit_at + INTERVAL 7 DAY))
```

CodeRouter per-user value (30d):

```sql
SELECT distinct_id, count() AS generations, sum(properties.$ai_total_cost_usd) AS api_equivalent_usd
FROM events
WHERE event = '$ai_generation' AND properties.product = 'coderouter'
  AND timestamp >= now() - INTERVAL 30 DAY
GROUP BY distinct_id ORDER BY api_equivalent_usd DESC LIMIT 25
```

Always filter `$ai_generation` on `properties.product = 'coderouter'`; other
products may emit the same PostHog event in this project.

## Enabling outside production

`services/analytics/serverEvents.ts` sends only when `VERCEL_ENV=production`
or `CMUX_SERVER_ANALYTICS_FORCE=1`. Test runs never reach the transport.
`cloud_vm_request` keeps its own `CMUX_VM_ANALYTICS_FORCE` flag.
