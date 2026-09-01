---
name: cmux-billing
description: "Stripe checkout, pricing, subscription, Pro plan, webhook, and entitlement runbook for cmux billing work. Use when editing or debugging billing, pricing, Stripe Checkout, subscription recording, Pro plan status, webhooks, entitlement metadata, or pricing dev/prod tooling."
---

# cmux Billing

Read before changing billing, pricing, Stripe, Pro entitlement, checkout, webhook, or subscription code.

## Architecture map

- `/api/billing/checkout` creates Stripe Checkout Sessions for Pro when `STRIPE_SECRET_KEY` is set. It sets `client_reference_id` to the Stack user id, auto-creates an anonymous Stack user for signed-out buyers, and falls back to the legacy Stack purchase path when Stripe is unset or `plan=team`. The "already active" short-circuit lives here.
- `/api/billing/portal` resolves the current Stack user, looks up their `stripe_customers` row, and creates a Stripe customer portal session returning to `/pricing`.
- `/api/billing/subscription` cancels or resumes the active Stripe Pro subscription; `/dashboard/billing` renders localized in-dashboard plan state and self-serve actions.
- `web/services/billing/purchase.ts` is the shared idempotent recorder used by `/api/billing/complete` and `/api/stripe/webhook`. It attaches email to the purchaser, records `billing_email_claims` on conflict, and never cross-grants based on an unverified email.
- `cmuxPlan` in Stack `clientReadOnlyMetadata` is the only entitlement VM code reads; a `cmuxVmPlan` manual override wins. `resolveProPlanStatus` ORs legacy Stack products with active `stripe_subscriptions` rows.
- `/api/stripe/webhook` is signature-verified, insert-first idempotent through `stripe_webhook_events`, safe for foreign events in the shared Stripe account, and gates cmux handling on `metadata.app === "cmux"`. Return 2xx only after durable writes; return 500 to make Stripe retry.

## Dev workflow

- Use `web/scripts/stripe/dev-stack.sh`.
- The tagged app bakes `CMUX_PORT` into `Info.plist`; run the dev server on the tag's printed port, never a hardcoded one.
- Per-branch Docker Postgres ports collide with other agents' containers. Use `--db-port` and never stop containers you did not create.
- `/app-pricing` requires `cmux_app=1`. `cmux_scheme` threads the native deeplink return scheme; `cmux-dev-*` schemes are honored only for localhost requests.
- Repeat dogfood: use a private window for a fresh anonymous buyer, and `web/scripts/stripe/dev-reset.sh <email>` to un-Pro a signed-in dev account before retesting checkout.
- Fake payment, two ways: `web/scripts/stripe/dev-grant.sh <email>` writes `cmuxPlan: "pro"` directly (instant, no checkout; undo with dev-reset). For the full checkout path at $0, enter promotion code `CMUXDEV100` in test-mode checkout — a 100%-off forever coupon in the test account; `allow_promotion_codes` is already set on checkout sessions.
- Newer Stripe CLI prints `stripe config --list` as `key=value` (older builds used `key = 'value'`); dev-stack.sh and dev-reset.sh accept both. If key extraction fails, re-run `stripe login`.

## Test-mode resources

Product `prod_UpIQRE6cj0nFjs`. New checkouts use `cmux-pro-monthly` ($30/mo) and `cmux-pro-yearly-288` ($288/yr, equivalent to $24/mo). Keep `cmux-pro-yearly` ($240/yr) active for grandfathered subscriptions. Staging webhook endpoint `we_1Tq1SZGhInAdn3JbWJReKNEN` forwards to `cmux-staging.vercel.app`; its secrets are already in the `cmux-staging` Vercel project.

## Feature flags

`pro-upgrade-ui-enabled-release` (PostHog id `741838`) gates all Pro UI and stays OFF in release until launch; DEBUG builds default it on. Public Pro and Team pricing CTAs always route through `/api/billing/checkout`, never the download confirmation page. `cmux __internal_flags`, once merged, inspects and overrides flags locally.

## Prod runbook

Run `web/scripts/stripe/provision-live.sh` with an operator key, add the two Vercel envs, deploy, validate live with a 100-percent-off promotion code purchase, then cancel.

DB migrations: `bun run cloud-vm:preflight`, `bun run cloud-vm:migrate -- staging`, staging deploy, then `bun run cloud-vm:migrate -- production`. Never run migrations from builds. See the Cloud VM ops flow.

## Gotchas

- `bun mock.module` is process-global, so every module mock must carry every real export other suite files import. A missing export can surface only in CI's test order as `Export named X not found`.
- Tests must not depend on `DATABASE_URL` being set.
- drizzle-1.0-beta wraps pg errors in `DrizzleQueryError`; read `error.cause` for the pg `code` and `constraint`.
- Pages outside `app/[locale]` need a `proxy.ts` bypass (like `/app-pricing` and `/billing`), or `next-intl` rewrites them into the locale tree and they 404 through missing root layout tags. Those subtrees also need their own layout with `html` and `body`.
