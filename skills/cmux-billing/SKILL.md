---
name: cmux-billing
description: "Stripe checkout, pricing, subscription, Pro plan, webhook, and entitlement runbook for cmux billing work. Use when editing or debugging billing, pricing, Stripe Checkout, subscription recording, Pro plan status, webhooks, entitlement metadata, or pricing dev/prod tooling."
---

# cmux Billing

Use this skill before changing billing, pricing, Stripe, Pro entitlement, checkout, webhook, or subscription code.

## Architecture Map

- `/api/billing/checkout` creates Stripe Checkout Sessions for Pro when `STRIPE_SECRET_KEY` is set. It sets `client_reference_id` to the Stack user id, auto-creates an anonymous Stack user for signed-out buyers, and falls back to the legacy Stack purchase path when Stripe is unset or `plan=team`.
- `/api/billing/portal` resolves the current Stack user, looks up their `stripe_customers` row, and creates a Stripe customer portal session returning to `/pricing`.
- `/api/billing/subscription` cancels or resumes the current user's active Stripe Pro subscription, and `/dashboard/billing` renders localized in-dashboard plan state and self-serve billing actions.
- `web/services/billing/purchase.ts` is the shared idempotent recorder used by both `/api/billing/complete` and `/api/stripe/webhook`. It attaches email to the purchaser, records `billing_email_claims` on conflict, and never cross-grants based on an unverified email.
- `cmuxPlan` in Stack `clientReadOnlyMetadata` is the only entitlement VM code reads. `cmuxVmPlan` manual override wins.
- `resolveProPlanStatus` ORs legacy Stack products with active `stripe_subscriptions` DB rows.
- `/api/stripe/webhook` is signature-verified, insert-first idempotent through `stripe_webhook_events`, safe for foreign events in the shared Stripe account, and gates cmux handling on `metadata.app === "cmux"`. Return 2xx only after durable writes; return 500 to make Stripe retry.

## Dev Workflow

- Use `web/scripts/stripe/dev-stack.sh`.
- The tagged app bakes `CMUX_PORT` into `Info.plist`; run the dev server on the tag's printed port. Do not hardcode a port.
- Per-branch Docker Postgres ports can collide with other agents' containers. Use `--db-port` and never stop containers you did not create.
- `/app-pricing` requires `cmux_app=1`.
- `cmux_scheme` threads the native deeplink return scheme. `cmux-dev-*` schemes are honored only for localhost requests.

## Repeat Dogfood

- Use a private window for a fresh anonymous buyer.
- Use `web/scripts/stripe/dev-reset.sh <email>` to un-Pro a signed-in dev account before retesting checkout.
- The "already active" short-circuit lives in `/api/billing/checkout`.

## Test-Mode Resources

- Product: `prod_UpIQRE6cj0nFjs`.
- Lookup keys: `cmux-pro-monthly` ($30/mo) and `cmux-pro-yearly` ($240/yr).
- Staging webhook endpoint: `we_1Tq1SZGhInAdn3JbWJReKNEN` forwarding to `cmux-staging.vercel.app`; secrets are already in the `cmux-staging` Vercel project.

## Feature Flags

- `pro-upgrade-ui-enabled-release` (PostHog id `741838`) gates all Pro UI and stays OFF in release until launch. DEBUG builds default the UI on.
- `pro-checkout-enabled-release` (PostHog id `741839`) routes the public pricing CTA.
- `cmux __internal_flags`, once merged, inspects and overrides flags locally.

## Prod Runbook

- Run `web/scripts/stripe/provision-live.sh` with an operator key, add the two Vercel envs, deploy, validate live with a 100 percent-off promotion code purchase, then cancel.
- DB migrations go through `bun run cloud-vm:preflight`, `bun run cloud-vm:migrate -- staging`, staging deploy, then `bun run cloud-vm:migrate -- production`. See the Cloud VM ops flow. Never run migrations from builds.

## Testing Gotchas

- `bun mock.module` is process-global, so every module mock must carry every real export other suite files import. Missing exports may surface only in CI's test order as `Export named X not found`.
- Tests must not depend on `DATABASE_URL` being set.
- drizzle-1.0-beta wraps pg errors in `DrizzleQueryError`; read `error.cause` for the pg `code` and `constraint`.

## Route Placement Gotcha

Pages outside `app/[locale]` need a `proxy.ts` bypass, like `/app-pricing` and `/billing`, or `next-intl` rewrites them into the locale tree and they 404 through missing root layout tags. Those subtrees also need their own layout with `html` and `body`.
