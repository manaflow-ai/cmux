---
name: cmux-billing
description: "Stripe checkout, pricing, subscription, Pro/Max/Go/Team plan, webhook, admin plan grant, Cloud VM allowance, and entitlement runbook for cmux billing work. Use when editing or debugging billing, pricing, Stripe Checkout, subscription recording, plan status, webhooks, entitlement metadata, or pricing dev/prod tooling."
---

# cmux Billing

Read before changing billing, pricing, Stripe, plan entitlement, checkout,
webhook, or subscription code. Lookup detail lives in references:

| Need | Read |
| --- | --- |
| Lookup keys, prices, yearly checkout, plan switching, legacy Founder grants, Stripe ids, a price change | [references/catalog.md](references/catalog.md#checkout-keys) |
| Cloud VM counts, vCPU/RAM pools, disk and machine-size limits per plan | [references/catalog.md](references/catalog.md#cloud-vm-allowance) |
| Staff admin grants, team overrides, email grants, admin downgrade | [references/admin.md](references/admin.md) |

## Invariants

- `/api/billing/checkout` creates Stripe Checkout Sessions for `go`, `pro`,
  `max` and `team`. A signed-out or anonymous buyer is redirected to sign in;
  when Stripe is not configured it redirects to `/pricing?billing=unavailable`
  (there is no legacy Stack purchase fallback). `go` is gated per user by
  `isGoPlanEnabled` (`services/billing/goPlanFlag.ts`). The "already active"
  short-circuit lives here. Public pricing CTAs always route through it, never
  the download confirmation page.
- `/api/billing/portal` creates a Stripe customer portal session from the
  user's `stripe_customers` row, returning to `/dashboard/billing` (or the team's
  billing page); only its error paths redirect to `/pricing`.
  `/api/billing/subscription` cancels or resumes the active subscription;
  `/dashboard/billing` renders plan state and self-serve actions.
- `web/services/billing/purchase.ts` is the shared idempotent recorder for
  `/api/billing/complete` and `/api/stripe/webhook`. It attaches email to the
  purchaser, records `billing_email_claims` on conflict, and never cross-grants
  based on an unverified email.
- `/api/stripe/webhook` is signature-verified, insert-first idempotent through
  `stripe_webhook_events`, safe for foreign events in the shared Stripe account,
  and gates cmux handling on `metadata.app === "cmux"`. Return 2xx only after
  durable writes; return 500 to make Stripe retry.
- Entitlement comes from Stack `clientReadOnlyMetadata`: a non-empty
  `cmuxVmPlan` (operator override) wins, otherwise `cmuxPlan` (the Stripe
  mirror). `resolveProPlanStatus` (`web/services/billing/pro.ts`) reports a paid
  plan for local dev Pro, an active Stripe subscription, an active App Store
  plan (the higher of the two wins), a paid `cmuxVmPlan` override, or a staff
  grant (`hasCompanyPlanGrant`). Paid plan ids are `go`, `pro`, `max`, `team`
  and `founders`. `billingManagement` is `stripe`, `external` (App Store, with
  an Apple `manageUrl`) or `none`, so a granted account shows Pro without a
  portal link.
- Stripe amounts are immutable: a price change mints a new lookup key and keeps
  the old one active for existing subscriptions
  ([how](references/catalog.md#changing-a-price)).
- Pricing copy must say Cloud VM resources are pooled, never per VM.

## Dev workflow

- Start the stack with `web/scripts/stripe/dev-stack.sh`.
- Local `bun dev` accounts on the development Stack project get a
  non-persistent Pro entitlement automatically, only when
  `CMUX_LOCAL_DEV_PRO=1`, `NODE_ENV=development`, `VERCEL_ENV` is unset, and
  `NEXT_PUBLIC_STACK_PROJECT_ID` is the development project. Release and preview
  deployments remain billing-backed. Use `dev-grant.sh` only to test an explicit
  manual grant or a non-local deployment.
- The tagged app bakes `CMUX_PORT` into `Info.plist`; run the dev server on the
  tag's printed port, never a hardcoded one.
- Per-branch Docker Postgres ports collide with other agents' containers. Use
  `--db-port` and never stop containers you did not create.
- `/app-pricing` requires `cmux_app=1`. `cmux_scheme` threads the native
  deeplink return scheme; `cmux-dev-*` schemes are honored only for localhost
  requests.
- Repeat dogfood: sign in with a fresh dev account (checkout requires
  sign-in), and `web/scripts/stripe/dev-reset.sh <email>` to un-Pro a dev account.
- Fake payment, two ways: `web/scripts/stripe/dev-grant.sh <email>` writes
  `cmuxVmPlan: "pro"` directly (the same override as `/api/admin/users`; undo
  with dev-reset). For the full checkout path at $0, enter promotion code
  `CMUXDEV100` in test-mode checkout; `allow_promotion_codes` is already set.
- Newer Stripe CLI prints `stripe config --list` as `key=value` (older builds
  used `key = 'value'`); the dev scripts accept both. If key extraction fails,
  re-run `stripe login`.

## Prod runbook

Run `web/scripts/stripe/provision-live.sh` with an operator key, add the two
Vercel envs, deploy, validate live with a 100-percent-off promotion code
purchase, then cancel.

DB migrations: `bun run cloud-vm:preflight`, `bun run cloud-vm:migrate -- staging`,
staging deploy, then `bun run cloud-vm:migrate -- production`. Never run
migrations from builds.

## Gotchas

- `bun mock.module` is process-global, so every module mock must carry every
  real export other suite files import. A missing export can surface only in
  CI's test order as `Export named X not found`.
- Tests must not depend on `DATABASE_URL` being set.
- drizzle-1.0-beta wraps pg errors in `DrizzleQueryError`; read `error.cause`
  for the pg `code` and `constraint`.
- Pages outside `app/[locale]` need a `proxy.ts` bypass (like `/app-pricing`
  and `/billing`), or `next-intl` rewrites them into the locale tree and they 404
  through missing root layout tags. Those subtrees also need their own layout
  with `html` and `body`.
