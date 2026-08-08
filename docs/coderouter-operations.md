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
- PostHog may contain aggregate token counts, outcomes, durations, user/team
  identity, and actual subscription cost basis.
- PostHog must never contain prompts, outputs, bodies, credentials, route
  tokens, email, payment-method details, or provider-account identifiers.
