# coderouter operations

This is the private-beta runbook for billing convergence, webhook replay,
latency evidence, and privacy-safe observability. Never paste route tokens,
OAuth credentials, request bodies, email addresses, or provider-account IDs
into tickets, logs, Sentry, PostHog, or ClickHouse.

## Access

Hosted coderouter and Subrouter are open to every signed-in user in every
team they belong to, including the personal team. Membership is the only
requirement: there is no Stack permission, team allow-list, or paid-plan
gate, and no connected-account cap. Route sessions and provider accounts are
scoped to the team the caller selects; a non-member gets `team_not_found`.

## Stripe webhook replay

1. Identify the failed Stripe event and the production `cmux.com` webhook
   endpoint in Stripe Workbench. Verify the event belongs to `app=cmux`.
2. Inspect without printing the complete payload:

   ```sh
   stripe events retrieve "$EVENT_ID" --live |
     jq '{id,type,created,pending_webhooks,livemode}'
   stripe webhook_endpoints list --live |
     jq '.data[] | {id,url,status}'
   ```

3. Redeliver the immutable signed event:

   ```sh
   stripe events resend "$EVENT_ID" \
     --webhook-endpoint "$CMUX_WEBHOOK_ENDPOINT_ID" \
     --live --confirm
   ```

4. Confirm `pending_webhooks=0`, the corresponding
   `stripe_webhook_events.error` is null, RDS matches Stripe, and an existing
   coderouter route token is accepted or rejected according to the resulting
   entitlement.

Webhook event IDs are idempotency keys. Never fabricate an event, manually
edit entitlement rows, or retry a different mutation as a substitute.

## Stripe/RDS reconciliation

The Vercel cron calls `/api/cron/billing-reconcile` at minute 23 every hour.
It requires `Authorization: Bearer $CRON_SECRET`, checks Stripe subscriptions
with bounded concurrency, and reuses the webhook's principal lock,
entitlement update, Stack metadata update, and route-token revocation path.
Stripe is authoritative.

For an operator run from a production-configured shell:

```sh
bun run coderouter:reconcile-billing --dry-run
bun run coderouter:reconcile-billing
```

The command prints counts only. Any failed or truncated run exits nonzero and
must be investigated. Do not expose the cron endpoint publicly or place
`CRON_SECRET` in command history.

## Latency evidence

```sh
bun run coderouter:benchmark --samples 30 > coderouter-benchmark.json
CODEROUTER_ROUTE_TOKEN=... \
  bun run coderouter:benchmark --samples 30 > coderouter-auth-benchmark.json
```

The checked-in harness drains responses, records status counts, reports
p50/p95/p99 client-to-edge latency, and parses every `Server-Timing` phase. A
route token belongs in an ephemeral environment variable only; never commit
the authenticated output if it contains a principal identifier.

## Observability

- Sentry project: `coderouter-web`; alert on new coderouter errors,
  reconciliation failure, refresh failure, and sustained provider failure.
- PostHog project: a dedicated CodeRouter-only project with AI Observability
  enabled and its project timezone pinned to UTC. Do not ingest ordinary cmux
  product analytics into it.
- CodeRouter model-usage events use PostHog's standard `$ai_generation`
  schema in content-free privacy mode. They contain token counts, the
  model/provider category required for pricing, and a pre-calculated
  API-equivalent estimate. They do not include a prompt, output, trace,
  request body, member identity, or raw Stack team ID.
- The stable team scope is HMAC-SHA256 with the independent
  `CODEROUTER_ANALYTICS_SCOPE_SECRET`; plain hashing is not sufficient because
  known team IDs would be guessable. Person-profile processing is disabled.
- PostHog must never contain prompts, outputs, bodies, credentials, route
  tokens, email, payment-method details, or provider-account identifiers.

### Usage ledger (ClickHouse)

Every model completion writes one `usage_events` row and every routed request
one `route_events` row to our own ClickHouse Cloud database, from the same
deferred `after()` path as the PostHog capture. Schema:
`web/db/clickhouse/001_coderouter_events.sql`. Rows hold token counts, the
rate-card estimate (`api_equivalent_usd`, `priced`, `rate_card_version`), the
raw team and Stack user IDs, the optional `vm_id`, provider, agent, model,
status, and a per-request `request_id` shared by the usage and route rows.
No prompt, output, header, or credential is ever written.

- Runtime env (Vercel production and preview, `~/.secrets/cmuxterm-dev.env`
  for local dev): `CLICKHOUSE_URL` (HTTPS interface, for example
  `https://<host>.clickhouse.cloud:8443`), `CLICKHOUSE_USER`,
  `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_DATABASE` (`coderouter` in production,
  `coderouter_dev` in preview and local dev). Unset means the ledger is
  disabled: writes are silent no-ops reported once as
  `coderouter.usage_ledger`, and usage panels show as unavailable.
- Scoped-user rule: the runtime user holds `SELECT` and `INSERT` on its own
  database only, no DDL. Every read binds values through ClickHouse query
  parameters (`{team_id:String}`); nothing is string-interpolated into SQL.
  Inserts use `async_insert=1&wait_for_async_insert=0` with a 2 s timeout so a
  proxied request never waits on ClickHouse; reads time out after 5 s.
- Migrations use the separate admin credential (`CLICKHOUSE_ADMIN_URL`,
  `CLICKHOUSE_ADMIN_USER`, `CLICKHOUSE_ADMIN_PASSWORD` in
  `~/.secrets/clickhouse.env`, never present in the app). Apply a schema
  change to both databases:

  ```sh
  set -a; source ~/.secrets/clickhouse.env; set +a
  cd web && bun run clickhouse:migrate coderouter_dev && bun run clickhouse:migrate coderouter
  ```

  The script runs each `web/db/clickhouse/*.sql` file in name order, one
  statement per request, with `{db}` substituted. All DDL is `IF NOT EXISTS`,
  so reruns are safe.

### Customer team-usage dashboard

- The dashboard reads the ClickHouse ledger (`web/services/coderouter/teamMetrics.ts`):
  per-day sums of `usage_events` for the last 30 UTC days, filtered by the
  authorized team ID after the server verifies Stack membership and
  CodeRouter permission. `docs/posthog/coderouter-team-usage-30d.hogql` is
  now for the PostHog operations dashboard only; the app no longer calls a
  PostHog Endpoint, and `POSTHOG_CODEROUTER_ENDPOINT_SECRET`,
  `POSTHOG_CODEROUTER_ENVIRONMENT_ID`, and `POSTHOG_CODEROUTER_API_HOST` are
  no longer read.
- Results are aggregate daily token totals and API-equivalent dollars only.
  Model identifiers are used at write time to derive the estimate from the
  versioned rate card in
  `web/services/coderouter/apiEquivalentPricing.ts`; neither model nor provider
  is returned to the customer.
- The estimate is not actual spend. Unknown models are excluded and surfaced
  through pricing coverage (`priced_tokens` / `unpriced_tokens`).
  Subscription-routed traffic remains `$0` incremental provider API spend.
- Responses are cached by team ID for five minutes. A disabled ledger,
  malformed rows, more than 30 day rows, timeouts, and query failures fail
  closed to an unavailable panel and never fall back to a cross-team or
  unfiltered query.
- Capture failures, ledger write failures, and ledger read failures emit
  privacy-safe `coderouter.analytics_delivery`, `coderouter.usage_ledger`, and
  `coderouter.analytics_query` Sentry errors. Alert on each in production.
  The report includes only a bounded failure reason and HTTP status, never a
  team ID, credential, SQL with values, request body, prompt, or model output.

### Customer per-machine usage

- `web/services/coderouter/vmMetrics.ts` runs the same 30-day query filtered
  by `vm_id`, and a per-machine query (`GROUP BY vm_id` where `vm_id IS NOT
  NULL`, at most 200 machines) for a team.
- `vm_id` is the cmux `cloud_vms.id` UUID written on every ledger row when the
  route token was bound to a Cloud VM. It is an opaque server-minted
  identifier, not personal data, and is only ever queried after the server
  confirms the machine belongs to the requesting billing team.
- `GET /api/coderouter/vm-usage?vmId=<uuid>` (dashboard or app session auth,
  `404 vm_not_found` for machines outside the team),
  `GET /api/coderouter/vm-usage/team` (same auth, one row per owned machine
  joined with `cloud_vms.display_name`), and
  `GET /api/coderouter/vm-usage/self` (VM-bound route token via the Freestyle
  edge, `403 vm_bound_token_required` for CLI tokens) serve the same
  30-day totals and daily series as the team dashboard. The dashboard
  Machines card reads the per-machine query through the same service.
- Caching, timeout, fail-closed behavior, and the `coderouter.analytics_query`
  Sentry error match the team-usage read. Loads emit
  `coderouter_vm_usage_viewed` with only a surface and outcome.

Hexclave Analytics remains the authorization system around this data, but is
not the metrics store today: its hosted custom-event ingestion currently
accepts only `$page-view` and `$click`. Reconsider it when Hexclave exposes a
server-authenticated, team-scoped custom-event ingestion API.
