# coderouter operations

This is the private-beta runbook for billing convergence, webhook replay,
latency evidence, and privacy-safe observability. Never paste route tokens,
OAuth credentials, request bodies, email addresses, or provider-account IDs
into tickets, logs, Sentry, or PostHog.

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

### Customer team-usage dashboard

- Publish `docs/posthog/coderouter-team-usage-30d.hogql` as the fixed
  `coderouter-team-usage-30d` PostHog Endpoint with a required `team_scope`
  string variable. Endpoints are PostHog's production/customer-facing
  analytics API; do not use the free-form Query API here.
- Set `POSTHOG_CODEROUTER_ENDPOINT_SECRET` to a CodeRouter-project secret API
  key with only `endpoint:read`. Project secret keys are project-scoped and
  are not tied to a person's wider PostHog permissions. Never expose it to
  browser code.
- The server verifies Stack membership and CodeRouter permission first, then
  derives the same keyed team scope used at capture time and passes only that
  scope to the fixed Endpoint.
- Results are aggregate daily token totals and API-equivalent dollars only.
  Model identifiers are used at event capture to derive the estimate from the
  versioned rate card in
  `web/services/coderouter/apiEquivalentPricing.ts`; neither model nor provider
  is returned by the Endpoint.
- The estimate is not actual spend. Unknown models are excluded and surfaced
  through pricing coverage. Subscription-routed traffic remains `$0`
  incremental provider API spend.
- Responses are cached by team ID for five minutes. Missing credentials,
  truncated or malformed PostHog data, timeouts, and Endpoint failures fail
  closed to an unavailable panel and never fall back to a cross-team,
  unfiltered, or free-form query.
- Capture failures and fixed-Endpoint read failures emit privacy-safe
  `coderouter.analytics_delivery` and `coderouter.analytics_query` Sentry
  errors. Alert on either error in production. The report includes only a
  bounded failure reason and HTTP status, never a team scope, team ID,
  Endpoint credential, request body, prompt, or model output.

Hexclave Analytics remains the authorization system around this data, but is
not the metrics store today: its hosted custom-event ingestion currently
accepts only `$page-view` and `$click`. Reconsider it when Hexclave exposes a
server-authenticated, team-scoped custom-event ingestion API.
