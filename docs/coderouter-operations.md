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
- PostHog dashboard: `coderouter private beta`; internal only.
- CodeRouter model-usage events use a hashed team-scoped distinct ID with
  person-profile processing disabled. They contain aggregate token counts,
  model/provider category, outcomes, durations, the immutable Stack team ID,
  and actual subscription cost basis, but no member identity.
- PostHog must never contain prompts, outputs, bodies, credentials, route
  tokens, email, payment-method details, or provider-account identifiers.

### Customer team-usage dashboard

- Set `POSTHOG_CODEROUTER_QUERY_API_KEY` to a dedicated PostHog personal API
  key with only `query:read`. Never reuse the broader account-deletion key or
  expose this key to browser code.
- The server verifies Stack membership and CodeRouter permission first, then
  derives the same one-way team analytics scope used at capture time and
  passes only that scope as a parameterized HogQL value.
- Results are aggregate daily request/token totals. Model identifiers are used
  server-side only to derive an API-equivalent estimate from the versioned rate
  card in `web/services/coderouter/apiEquivalentPricing.ts`; they are not
  returned to the page.
- The estimate is not actual spend. Unknown models are excluded and surfaced
  through pricing coverage. Subscription-routed traffic remains `$0`
  incremental provider API spend.
- Responses are cached by team ID for five minutes. Missing credentials,
  malformed PostHog data, timeouts, and query failures fail closed to an
  unavailable panel and never fall back to a cross-team or unfiltered query.
