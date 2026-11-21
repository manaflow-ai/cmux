# NEXT billing: go-live status (one page)

Leo, 2026-11-10: "Let's make some money, man." The goal is that the go, which the founders make, is one flip. Read from the
code on 2026-11-10 (cmux feat-cmux-next, cmux-platform main). Details: `usage-billing.md`.

Leo's decisions in force: model overage at the provider's list price plus 10%; at a team's spending
cap, members' new starts are refused and machines pause after a 15-minute warning, nothing lost.

## Works (development and staging, behind flags; tested)

| Stage | Where | Flag | Tests |
|---|---|---|---|
| Plan picker (native) | Mac app `PaidPlanUpgrade` -> cmux.com `/api/billing/checkout` (classic web, frozen) | app `BillingLivePolicy.shipped.liveCheckout` (false) | `PaidPlanUpgradeTests`, `BillingCheckoutTests` |
| Entitlements | cmux-platform `Entitlements.ts`, `Plan.ts` (reads `cmuxPlan` through TeamDO) | `CLOUD_PLAN_ENTITLEMENTS=on` | `cloud-entitlements`, `cloud-capability` |
| Machine-time meter | cmux-platform `UsageLedger.ts` -> cmux-api `UsageMeterDO` (`cloud.machine_usd`) | `CLOUD_USAGE_LEDGER=on` + `USAGE_METER_DO` | `cloud-usage-ledger` |
| Overage at list + 10% | cmux-api `billing-catalog.ts` `billedLevelMicros`, `overageModelMarkup` (1.1 under price set v2); model cost is the provider's reported cost, else the catalog card price | `BILLING_USAGE_PRICE_SET=v2` | `billing-price-set`, `team-overage-cap` |
| Usage to Stripe | cmux-api `billing-usage-sync.ts` (meter events, test keys only) | `STRIPE_USAGE_KEY` (test) | `usage-meter`, `billing-price-set` |
| Team cap, model calls | cmux-api `team-cap.ts`, refused in `reserveUser` | v2 only | `team-overage-cap` |
| Team cap, machines | cmux-platform `SpendCap.ts` + `CloudDO`: starts refused, `pause_at` = +15 min, pause on the normal path, `paused_by: spend_cap` | `CLOUD_SPEND_CAP=on` | `cloud-spend-cap` (27 cases) |
| Cap UI | webviews `spendCap.ts`, `SpendCapBanner`, start-card copy | server state | `spendCap.test.ts` |
| Credit top-ups | cmux-api `credits-checkout.ts` (Checkout, test keys only) | `STRIPE_CREDITS_KEY` | `credits-fast-checkout` |

## Missing (and the PR that closes it)

1. The cap learned of model spend late: cmux-platform read the team cap after a ledger run or hourly, so a team
   whose models crossed the cap could run machines up to an hour before the 15-minute warning started.
   cmux-platform#1143: it adds unledgered machine time and reads every 5 minutes.
2. No Stripe-pushing deployment ran Leo's rules: staging was on v1, and development's `e2e` set was pass-through.
   This PR: `e2e` bills by v2's rules (`billsLikeV2`), staging runs v2, and production takes v2 when its var says so.
3. The usage sync refused every live key, and the live switch (`usage-billing.md` section 12) was prose.
   cmux#40319: built and off (`USAGE_LIVE_ENABLED = false`, production plus `rk_live_` only, livemode check,
   allowlist, dry run).
4. Webview "See plans" links the pricing page; `cloud.billing.checkout` has no handler in cmux-platform. The
   native app's checkout (classic web, Stripe test mode on staging) is the purchase path today.
5. Stripe receipt email: no code of ours sends one. It is the Stripe account's "Successful payments" email
   setting (Dashboard, Settings, Customer emails).
6. No overage-dollar line in the Cloud page, and no team-cap setting UI (the op `usage.cap.set` exists).
7. The live catalog: `backend/scripts/stripe-usage-catalog.ts` makes test-mode prices only.

## Untested

- Any purchase end to end through the NEXT app (the October runs drove Stripe from a script).
- The cap pause against a live `UsageMeterDO` (unit tests use a stub). `stripe-usage-e2e.ts` PHASE=cap covers
  it on development once run.
- `AccountPanel` usage rows, the activation refresh after checkout (`paidPlanReturned`).

## Production today (all off)

- cmux-api: no `BILLING_USAGE_PRICE_SET`, no `STRIPE_USAGE_KEY`, `USAGE_HARD_STOP_UNBILLED` unset,
  `USAGE_LIVE_ENABLED = false`.
- cmux-platform: no `CLOUD_PLAN_ENTITLEMENTS`, `CLOUD_USAGE_LEDGER`, `USAGE_METER_DO` or `CLOUD_SPEND_CAP`
  (`scripts/inert-rules.ts` enforces it).
- App: `liveCheckout` is false. HOLD PR #26757 carries the entitlements var.

## The go (the founders' step, not an agent's)

In order:
1. Create the restricted live key (Dashboard: Billing meter events Write, Subscriptions Read, Subscription items
   Write, Prices Read, Customers Read). Set it on production cmux-api as `STRIPE_USAGE_KEY`.
2. Make the live `-v2` usage catalog.
3. Merge one change that sets all of these:
   - `USAGE_LIVE_ENABLED = true`;
   - cmux-api production `BILLING_USAGE_PRICE_SET=v2` and `BILLING_USAGE_LIVE_ALLOW=<staff subscriptions>`;
   - cmux-platform production `CLOUD_PLAN_ENTITLEMENTS`, `CLOUD_USAGE_LEDGER`, `CLOUD_SPEND_CAP` and the
     `USAGE_METER_DO` binding.
4. Run one dry run (`POST /v1/internal/billing/sync {"dry_run": true}`).
5. Remove the allowlist.
