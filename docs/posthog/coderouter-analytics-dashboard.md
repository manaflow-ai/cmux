# CodeRouter PostHog dashboards

The current CodeRouter product dashboard is **Cloud VMs + CodeRouter
(product)** in the main cmux PostHog project (`244066`). It is managed by
`cmuxterm-hq/scripts/posthog-cloud-dashboard.py` and reads the catalog in
`posthog_cloud_metrics.py`.

The former **CodeRouter Operations & Usage** dashboard in project `549394` is
historical. The application no longer writes new events there. Do not build
new customer or product reports from that project.

## Event rules

Filter every CodeRouter tile with:

```sql
WHERE event = '$ai_trace' AND properties.product = 'coderouter'
```

Use the canonical event names and fields:

| Question | Event | Fields |
| --- | --- | --- |
| Request volume and success | `$ai_trace` | `$ai_is_error`, `coderouter_outcome`, `coderouter_failure_stage`, `coderouter_fault`, `coderouter_provider`, `coderouter_agent` |
| Request latency | `$ai_trace` | `$ai_latency` (seconds), `coderouter_attempts` |
| Failure stage | `$ai_trace` | `coderouter_failure_stage`, `coderouter_outcome`, `coderouter_fault` |
| Tokens and API-equivalent value | `$ai_generation` | `$ai_input_tokens`, `$ai_cache_read_input_tokens`, `$ai_output_tokens`, `coderouter_total_tokens`, `$ai_total_cost_usd` |
| Pricing coverage | `$ai_generation` | `coderouter_priced_tokens`, `coderouter_unpriced_tokens`, `coderouter_total_tokens` |
| Cloud VM share | `$ai_generation` or `$ai_trace` | `coderouter_vm_id IS NOT NULL` |
| Account and session lifecycle | lifecycle events | `coderouter_account_*`, `coderouter_route_session_*` |

Exclude `distinct_id = 'coderouter-server'` from person-level product counts.
That id is for unauthenticated requests and operator events. The same Stack
user id is used by Cloud VM product events, so cross-product joins use
`distinct_id`.

`$ai_generation` is emitted only when a completion has usable token usage. A
failure is a `$ai_trace` with `$ai_is_error = true`; there is no
`coderouter_request_failed` event. Divide failed traces by all known-user
traces when calculating failure rate. Do not divide by failed plus
generations, because requests can fail before a generation exists.

## Privacy and integrity checks

Every tile and alert must preserve these rules:

* no prompts, outputs, request bodies, credentials, emails or route tokens;
* `$geoip_disable = true`;
* user events use a bounded Stack user id and team events use the
  `$groups.stack_team` group;
* `coderouter_priced_tokens + coderouter_unpriced_tokens` equals
  `coderouter_total_tokens`;
* cached input tokens do not exceed input tokens;
* API-equivalent dollars are labeled as a list-price estimate, not cmux spend.

Any violation is an incident. The ClickHouse ledger remains the source for
customer-facing team and machine usage; PostHog is for product and operations
analysis.

## Recommended views

1. Requests, failures and p50/p95 latency by day from `$ai_trace`.
2. Failure stage, outcome, fault and provider from failed `$ai_trace` rows.
3. Tokens, pricing coverage and API-equivalent estimate by day from
   `$ai_generation`.
4. Agent and provider mix from `$ai_trace` and `$ai_generation`.
5. Cloud VM versus local traffic from `coderouter_vm_id`.
6. Account-added to route-session-issued to first-generation activation.
7. Cloud VM and CodeRouter overlap, joined on the Stack `distinct_id`.

For the managed dashboard, run the dashboard script in dry-run mode first. It
executes every HogQL query before it changes any insight:

```sh
POSTHOG_PERSONAL_API_KEY=... python3 scripts/posthog-cloud-dashboard.py --dry-run
```

Never put a PostHog key in source, a ticket, or chat. Remove the retired
`POSTHOG_CODEROUTER_*` and `CODEROUTER_ANALYTICS_SCOPE_SECRET` variables only
after checking for remaining operator consumers.
