# Cloud VM and CodeRouter product analytics (PostHog)

Project: the main cmux project (`244066`), the same project as desktop
`cmux_daily_active`, signed-in web, iOS and Stripe billing events.

Dashboard: **Cloud VMs + CodeRouter (product)**, built and refreshed by
`scripts/posthog-cloud-dashboard.py` in cmuxterm-hq. The daily analytics email
(`scripts/analytics-report.py`) reads the same query catalog
(`scripts/posthog_cloud_metrics.py`) and links to the dashboard.

These events are emitted by the web server. No CLI or Swift client sends them.

## Identity model

| Concept | Value |
| --- | --- |
| `distinct_id` | Stack user id when the request has an authenticated person. |
| `$groups.stack_team` | Stack billing team id, for account-level rollups. |
| person `$set` | `billing_plan` from the plan that authorized a Cloud VM event. |
| person `$set_once` | `cloud_vm_first_created_at` and `cloud_vm_first_attached_at` for Cloud VM lifecycle events. |
| `$lib` | `cmux-web-server` on Cloud VM events sent through `services/analytics/serverEvents.ts`. |

The shared sender accepts only bounded opaque Stack ids (`[A-Za-z0-9_-]`),
trims and bounds all strings, drops free-form metadata, disables IP
geolocation, and gives every event an `$insert_id`. Create and destroy use
`cloud_vm_created:<vm id>` and `cloud_vm_destroyed:<vm id>` so a replay cannot
double count the same machine fact. Other lifecycle rows use a generated
insert id because each row is an action.

There are two machine-id forms and they must not be joined blindly:

* `cloud_vm_*` lifecycle events use the internal `cloud_vms.id` UUID.
* `cloud_vm_request` uses the provider VM id from the URL (`/api/vm/<id>/...`).
  It is a client-facing name and is not the internal UUID.
* CodeRouter uses `coderouter_vm_id`, the internal UUID, when a route token is
  bound to a Cloud VM.

## Cloud VM events

Source: the `cloud_vm_usage_events` ledger. Every workflow writes one row per
lifecycle fact. `services/vms/productAnalytics.ts` decorates the repository,
so the PostHog event is emitted only after the Postgres insert succeeds. A
PostHog failure never changes the workflow, and a failed ledger insert never
creates a product event. Failures remain in `cloud_vm_request` and
`cloud_vm_provision`.

Common properties: `product: cloud_vm`, `ledger_event`, internal `vm_id`,
`provider`, `image_id`, `plan_id`, `billing_team_id`, `schema_version: 1`.

| Event | Ledger row | Extra properties |
| --- | --- | --- |
| `cloud_vm_created` | `vm.created` | `origin` (`create`, `restore`, `fork`, `base`), `image_version`, `image_size`, `memory_mb`, `persistent_home`, `per_machine_home`, `idempotency_key_set` |
| `cloud_vm_destroyed` | `vm.destroyed` | `reason` (`user_request`, `provider_status_cron`, `provider_status_refresh`, `base_open_provider_missing`, or `unknown`), `lifetime_seconds`, `home_volume_deleted` |
| `cloud_vm_attached` | `vm.attach` | `transport`, `invited` |
| `cloud_vm_exec` | `vm.exec` | `exit_code`, `command_length` |
| `cloud_vm_forked` | `vm.forked` | `native`, `idempotency_key_set` |
| `cloud_vm_resumed` | `vm.resumed` | `source` |
| `cloud_vm_snapshot_created` | `vm.snapshot.created` | `named` |
| `cloud_vm_port_opened` | `vm.open_port` | `port` |
| `cloud_vm_base_opened` | `vm.base.opened` | `generation` |
| `cloud_vm_base_reset` | `vm.base.reset` | `generation` |

Request telemetry (`cloud_vm_request`, schema 2, and
`cloud_vm_provision`, schema 3) carries the request machine name, billing
scope, client fields and the `stack_team` group. Paywall and limit failures
(`vm_requires_pro`, `vm_active_limit_exceeded`, `vm_access_requires_pro`,
`vm_create_credits_insufficient`) can therefore be broken down by plan and
team. `approve_cmux_remote_enrollment` is a polled operation: successful
polls do not produce request rows, while failures still do.

The account-deletion destroy row is intentionally not mirrored. The deletion
flow removes the PostHog person before provider teardown; sending a later
user-keyed event would recreate that person. The Postgres ledger remains the
audit source for those destroys.

## CodeRouter events

PostHog is only for CodeRouter lifecycle and operational exception events.
ClickHouse is the authoritative source for every routed request, model
completion, token count, provider, model, latency, failure, and VM attribution.

| Event | When | Properties |
| --- | --- | --- |
| `coderouter_account_added` / `_removed` | Provider account lifecycle | Closed-schema provider and source fields, plus bounded state flags |
| `coderouter_route_session_issued` / `_revoked` | Route-session lifecycle | No free-form fields |
| `coderouter_claude_upstream_set` / `_removed` | Claude upstream lifecycle | Closed-schema upstream kind and replacement flag |

Lifecycle events carry `product: coderouter` and the current schema version.
Non-caller failures also produce a `$exception`. The route request id is
shared with ClickHouse and Axiom, but no request-level LLM trace or token event
is sent to PostHog. ClickHouse stores the versioned API-equivalent list-price
estimate, not cmux spend.

The application no longer writes new CodeRouter events to the former dedicated
project (`549394`). Its old dashboards and environment keys are legacy; remove
the keys only after confirming that no remaining runtime or operator workflow
uses them.

## Query shapes

Cloud active user on a day: any Cloud VM lifecycle event.

```sql
SELECT toStartOfDay(timestamp) AS d, count(DISTINCT distinct_id) AS users
FROM events
WHERE event IN ('cloud_vm_created','cloud_vm_attached','cloud_vm_exec','cloud_vm_forked',
                'cloud_vm_resumed','cloud_vm_snapshot_created','cloud_vm_port_opened',
                'cloud_vm_base_opened','cloud_vm_base_reset')
  AND timestamp >= now() - INTERVAL 30 DAY
GROUP BY d ORDER BY d
```

CodeRouter per-user usage (30d, ClickHouse):

```sql
SELECT stack_user_id, count() AS completions,
       sum(total_tokens) AS total_tokens,
       sum(api_equivalent_usd) AS api_equivalent_usd
FROM coderouter.usage_events
WHERE event_time >= now() - INTERVAL 30 DAY
GROUP BY stack_user_id ORDER BY api_equivalent_usd DESC LIMIT 25
```

CodeRouter failure rate uses ClickHouse route rows for the denominator:

```sql
SELECT toStartOfDay(event_time) AS d,
       count() AS requests,
       countIf(status >= 400 OR outcome != 'success') AS failed,
       round(100 * countIf(status >= 400 OR outcome != 'success') / max2(1, count()), 1) AS failure_pct
FROM coderouter.route_events
WHERE event_time >= now() - INTERVAL 30 DAY
GROUP BY d ORDER BY d
```

## Enabling outside production

`services/analytics/serverEvents.ts` sends Cloud VM product events only when
`VERCEL_ENV=production` or `CMUX_SERVER_ANALYTICS_FORCE=1`. CodeRouter uses
`VERCEL_ENV=production` or `CODEROUTER_ANALYTICS_FORCE=1`. Test runs do not reach
the PostHog transport unless a test supplies its own fetch implementation.
