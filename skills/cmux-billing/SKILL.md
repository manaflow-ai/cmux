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
<<<<<<< HEAD
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
=======
  `NEXT_PUBLIC_STACK_PROJECT_ID` is the development project. Release and
  preview deployments remain billing-backed. Use `dev-grant.sh` only when
  testing an explicit manual grant or a non-local deployment.
- The tagged app bakes `CMUX_PORT` into `Info.plist`; run the dev server on the tag's printed port, never a hardcoded one.
- Per-branch Docker Postgres ports collide with other agents' containers. Use `--db-port` and never stop containers you did not create.
- `/app-pricing` requires `cmux_app=1`. `cmux_scheme` threads the native deeplink return scheme; `cmux-dev-*` schemes are honored only for localhost requests.
- Repeat dogfood: use a private window for a fresh anonymous buyer, and `web/scripts/stripe/dev-reset.sh <email>` to un-Pro a signed-in dev account before retesting checkout.
- Fake payment, two ways: `web/scripts/stripe/dev-grant.sh <email>` writes `cmuxVmPlan: "pro"` directly (same override as `/api/admin/users`) (instant, no checkout; undo with dev-reset). For the full checkout path at $0, enter promotion code `CMUXDEV100` in test-mode checkout: a 100%-off forever coupon in the test account; `allow_promotion_codes` is already set on checkout sessions.
- Newer Stripe CLI prints `stripe config --list` as `key=value` (older builds used `key = 'value'`); dev-stack.sh and dev-reset.sh accept both. If key extraction fails, re-run `stripe login`.

## Catalog

Prices live in `web/services/billing/plans.ts` and are provisioned by `web/scripts/stripe/provision-catalog.sh`. Current checkout keys: `cmux-starter-monthly-15` ($15/mo, Plus; internal plan ID `go`), `cmux-pro-monthly-50` ($50/mo), `cmux-pro-yearly-480` ($480/yr, $40/mo equivalent), `cmux-max-monthly-200` ($200/mo), `cmux-max-yearly-1920` ($1,920/yr, $160/mo equivalent), and `cmux-team-monthly-60` ($60/user/mo). Pro and Max use the same 20% annual discount. Go and Team remain monthly-only. Go and Max are personal plans like Pro: the user-scoped subscription row's `plan` column is derived from its Price lookup key (`personalPlanIdForSubscription`), `cmuxPlan` mirrors the exact purchased plan, and every `isPro` check passes. Every Max and Pro CTA links `/api/billing/checkout`, and `web/services/billing/personalSwitchRoute.ts` decides where an existing subscription goes (the portal route uses the same function for old `flow=switch_plan` links, so the two never disagree or loop). A monthly subscription on a price the switch portal lists (`PORTAL_SWITCHABLE_LOOKUP_KEYS`: Pro monthly and both Max intervals) opens Stripe's subscription-update flow with the portal configuration stamped `metadata.purpose=personal_plan_switch` (the script provisions it; the account default configuration stays quantity-only). A yearly, grandfathered or Go subscription opens the dashboard's switch dialog (`/dashboard/billing?change=max`), which keeps the billing interval and prices any subscription. An account with no subscription to switch (an operator grant, a company account or Founder's Edition) buys Max through a new Checkout. Founder's Edition is a one-time purchase of Pro for life, stored as an active Pro row marked `founders_edition`; it is never a subscription to switch or cancel. A founder on Max returns to Pro by cancelling Max (the dashboard's Pro card opens that cancel dialog), never by switching onto a paid Pro price, and `planChange.ts` refuses that switch. Stripe amounts are immutable, so a price change mints a new lookup key carrying the amount and adds the old key to `LEGACY_PRICE_LOOKUP_KEYS`; grandfathered Prices (`cmux-pro-monthly` $30, `cmux-pro-yearly` $240, `cmux-pro-yearly-288` $288, `cmux-team-monthly` $35, `cmux-team-yearly-336` $336, `cmux-team-yearly-576` $576) stay active for the subscriptions on them and `/dashboard/billing` prices every row from its own Stripe amount. Env price-id overrides carry the amount in their name (`STRIPE_PRO_MONTHLY_50_PRICE_ID`, `STRIPE_PRO_YEARLY_480_PRICE_ID`, `STRIPE_MAX_MONTHLY_200_PRICE_ID`, and `STRIPE_MAX_YEARLY_1920_PRICE_ID`); a retired name fails env validation, so delete it from Vercel before deploying a price change. Test-mode Pro product `prod_UpIQRE6cj0nFjs` (Max `prod_VOppwEzT7jtBNW`; Max monthly `price_1UO29QGhInAdn3JbD2Cld8PX`, annual `price_1UOl71GhInAdn3JbYWi9kguZ`; switch portal `bpc_1UO2AIGhInAdn3JbgNBD6OZD`); live Pro product `prod_Uq4a28vk0fP3E6`; live Max product `prod_VEpRwst8UwD5cm` (Max monthly `price_1UELmdGhInAdn3Jb8Gpe9ilK`, annual `price_1UOl9ZGhInAdn3Jb8g9BoXSx`, switch portal `bpc_1UELmeGhInAdn3JbgZqLIbP0`). `STRIPE_PERSONAL_PLAN_SWITCH_PORTAL_CONFIGURATION_ID` is pinned in Vercel (production = live id, development and preview = test id) so the restricted production key never has to list portal configurations. Staging webhook endpoint `we_1Tq1SZGhInAdn3JbWJReKNEN` forwards to `cmux-staging.vercel.app`; its secrets are already in the `cmux-staging` Vercel project.

The paid Cloud VM allowance lives in `web/services/vms/machineSpec.ts` and `web/services/vms/entitlements.ts`. A paid seat buys up to 5 saved Cloud VMs, including paused machines that share vCPU and RAM pools: Pro and Founder's Edition share 20 vCPUs and 40 GB RAM; Max shares 80 vCPUs and 160 GB RAM. Team has one team pool of 20 vCPUs and 40 GB RAM per paid seat (multiplied by `cmuxSeats` like the 5-VM count) shared by every member, not a separate allowance per user. The user divides the pool however they like. Only `provisioning` and `running` VMs draw from the compute pool; paused VMs still occupy a saved-machine slot. Disk is a per-VM limit and is not pooled: Plus/Pro/Team/Founder's grow to 128 GB, and Max to 256 GB. The largest single VM is 8 vCPU / 16 GB RAM (the `lg` row) on Pro, Team, and Founder's, and 32 vCPU / 64 GB RAM (the `2xl` row) on Max (`maxMemoryMbForPlan`). Plus allows one saved VM total, including paused machines, with Pro’s machine sizes, up to 8 vCPU / 16 GiB RAM and 128 GiB disk, with no monthly hour cap. Legacy provider runtime caps and pause intents are cleared on access or by the minute job. The original $10 Go Price stays active only for grandfathered subscriptions. Web Plus is public; App Store Go retains its independent rollout flag. The default machine has 8 GB RAM and 32 GB disk. The repository enforces both the machine count and the pool under the billing-team lock on create, Base open/reset, paused resume, resize, and fork, using each VM's stored resource reservation (legacy rows without a marker conservatively reserve the provider maximum until reconciliation measures them). A request over the pool fails with a typed resource-pool error that names the pool, the amount in use, and the request; `GET /api/vm` limits publish the pool and its usage. The machine list publishes `lockedMemoryOptionsMb` and `memoryUpgradePlanId`, and a create that asks for a locked size gets `402 vm_memory_requires_plan` instead of a silently smaller machine. Pricing copy must say the resources are pooled, never per VM. Paid-limit environment overrides are retired; the create kill switch remains the incident control.

Pro and Max sell yearly: `interval=year&plan=pro` checks out `cmux-pro-yearly-480` ($480/yr, 20% off; env override `STRIPE_PRO_YEARLY_480_PRICE_ID`) and `interval=year&plan=max` checks out `cmux-max-yearly-1920` ($1,920/yr, 20% off; env override `STRIPE_MAX_YEARLY_1920_PRICE_ID`). Go and Team `interval=year` requests return `annual_unavailable` before creating Stripe state, and their historical annual prices stay active only for existing subscriptions. The personal plan-switch portal lists Pro monthly and both Max intervals; yearly subscribers switch in the dashboard instead. The Pro and Max pricing cards own the billing period, so each plan's price, checkout link, and CTA analytics (`interval`, `discount_percent`) always agree.

## Feature flags

Pro upgrade entrypoints and public pricing navigation no longer use a rollout flag. The sidebar badge still respects its local dismissal preference. Public Pro and Team pricing CTAs always route through `/api/billing/checkout`, never the download confirmation page. `cmux __internal_flags`, once merged, inspects and overrides flags locally.
>>>>>>> origin/main

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
