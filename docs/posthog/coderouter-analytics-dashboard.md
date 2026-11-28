# CodeRouter analytics

CodeRouter usage is a ClickHouse concern. Do not build PostHog tiles from
`$ai_generation`, `$ai_trace`, `$ai_span`, token properties, or cost fields.
The ClickHouse tables are `coderouter.usage_events` (one row per completion)
and `coderouter.route_events` (one row per routed request). `usage_events`
carries token, pricing, model, and provider fields. `route_events` carries
status, outcome, failure stage, duration, and provider fields. Both tables
carry team, Stack user, agent, and optional Cloud VM attribution fields.

PostHog remains useful for low-volume product lifecycle events:
`coderouter_account_added`, `coderouter_account_removed`,
`coderouter_route_session_issued`, `coderouter_route_session_revoked`, and
`coderouter_claude_upstream_*`. These events use the Stack user as
`distinct_id` and the billing team as `stack_team`; they contain no usage or
token values.

The managed Cloud VM dashboard includes the lifecycle tile for account
connections. The daily email reads all CodeRouter usage and failure metrics
from ClickHouse. If ClickHouse is unavailable, the email says so and never
falls back to PostHog.

Example queries:

```sql
SELECT toStartOfDay(event_time) AS day,
       uniqExactIf(stack_user_id, stack_user_id != '') AS users,
       count() AS completions,
       sum(total_tokens) AS tokens,
       sum(api_equivalent_usd) AS api_equivalent_usd
FROM coderouter.usage_events
WHERE event_time >= now() - INTERVAL 30 DAY
GROUP BY day ORDER BY day;
```

```sql
SELECT toStartOfDay(event_time) AS day,
       count() AS requests,
       countIf(status >= 400 OR outcome != 'success') AS failed
FROM coderouter.route_events
WHERE event_time >= now() - INTERVAL 30 DAY
GROUP BY day ORDER BY day;
```

API-equivalent dollars are list-price estimates for the routed tokens, not
cmux spend. Customer-facing usage and billing reports must use ClickHouse.
