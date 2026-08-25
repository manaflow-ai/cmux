# CodeRouter PostHog dashboards

Project: **CodeRouter Analytics** (dedicated; never the general cmux project)

Dashboard: **CodeRouter Operations & Usage**

All event queries must filter `product = 'coderouter'` and current
`schema_version`. Team/user scopes are HMAC pseudonyms; never add raw IDs,
names, labels, prompts, output, credentials, paths, arguments, URLs, headers,
request IDs, or free-form errors.

## P0 cards

1. **Requests and success rate**
   - Event: `coderouter_route_health`
   - Requests: count
   - Success: `outcome = success`
   - Breakdown: provider, agent, outcome
2. **Route latency**
   - Event: `coderouter_route_health`
   - Breakdown: `latency_bucket`
3. **Retries and refreshes**
   - Event: `coderouter_route_health`
   - Breakdown: `attempt_bucket`, `refresh_bucket`
4. **Failure stage**
   - Event: `coderouter_route_health`
   - Breakdown: `failure_stage`, `status_class`
5. **Tokens by day**
   - Event: `$ai_generation`
   - Sums: `$ai_input_tokens`, `$ai_cache_read_input_tokens`,
     `$ai_output_tokens`, `coderouter_total_tokens`
6. **API-equivalent value**
   - Event: `$ai_generation`
   - Sum: `$ai_total_cost_usd`
   - Label explicitly as an estimate, not actual provider spend
7. **Pricing coverage**
   - Event: `$ai_generation`
   - `sum(coderouter_priced_tokens) / sum(coderouter_total_tokens)`
8. **Active pseudonymous organizations**
   - Unique `coderouter_team_scope`
9. **CLI command funnel**
   - `coderouter_cli_command_started` → `coderouter_cli_command_completed`
   - Breakdown: command, agent, mode, outcome, failure_stage
10. **Account lifecycle**
    - `coderouter_account_status_viewed`
    - `coderouter_account_added`
    - `coderouter_account_removed`
11. **Session lifecycle**
    - `coderouter_route_session_issued`
    - `coderouter_route_session_revoked`
    - `coderouter_auth_rejected`
12. **Organization and dashboard use**
    - `coderouter_organization_catalog_viewed`
    - `coderouter_metrics_loaded`

## P0 privacy/integrity cards

Each must remain zero:

- missing `coderouter_team_scope` on team-scoped events
- `distinct_id != coderouter_team_scope`
- `$process_person_profile != false`
- `$geoip_disable != true`
- unknown `schema_version`
- `cached_input_tokens > input_tokens`
- `priced_tokens + unpriced_tokens != total_tokens`
- forbidden property keys (`prompt`, `output`, `$ai_input`,
  `$ai_output_choices`, `credential`, `authorization`, `cookie`, `account_id`,
  `team_id`, `user_id`, `email`, `local_path`, `command_args`)

Any nonzero privacy/integrity card is an incident.

## P1 views

- Weekly organization retention: successful `coderouter_route_health` return.
- Activation funnel:
  account added → route session issued → successful route health.
- Provider/agent mix over time.
- CLI version adoption and failure rate by version.
- Metrics Endpoint availability by `outcome` and `failure_stage`.

## Alerts

- route success below 97% with at least 20 eligible requests/hour
- `no_usable_account` above 5%/hour
- 5xx above 2%/hour
- 10s+ latency above 5%/hour
- pricing coverage below 95% daily
- any privacy/integrity violation
- no successful events during expected active periods

Customer-facing metrics must continue to use the fixed,
server-authorized `coderouter-team-usage-30d` Endpoint. Never expose PostHog
project access or free-form HogQL to customers.
