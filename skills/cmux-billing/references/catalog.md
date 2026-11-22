# Plans, prices and plan switching

Lookup detail for [../SKILL.md](../SKILL.md). Prices live in
`web/services/billing/plans.ts` and are provisioned by
`web/scripts/stripe/provision-catalog.sh`.

## Checkout keys

| Lookup key | Price | Notes |
| --- | --- | --- |
| `cmux-starter-monthly-15` | $15/mo | cmux Plus, internal plan id `go`; monthly only; offered to every web visitor (`isWebPlusPlanEnabled`); App Store Go keeps `isGoPlanEnabled` |
| `cmux-pro-monthly-50` | $50/mo | |
| `cmux-pro-yearly-480` | $480/yr | $40/mo equivalent, 20% off |
| `cmux-max-monthly-200` | $200/mo | |
| `cmux-max-yearly-1920` | $1,920/yr | $160/mo equivalent, 20% off |
| `cmux-team-monthly-60` | $60/user/mo | monthly only |

Go and Max are personal plans like Pro: the user-scoped subscription row's
`plan` column is derived from its Price lookup key
(`personalPlanIdForSubscription`), `cmuxPlan` mirrors the exact purchased plan,
and every `isPro` check passes.

## Yearly checkout

`interval=year&plan=pro` checks out `cmux-pro-yearly-480` (env override
`STRIPE_PRO_YEARLY_480_PRICE_ID`) and `interval=year&plan=max` checks out
`cmux-max-yearly-1920` (env override `STRIPE_MAX_YEARLY_1920_PRICE_ID`). Go and
Team `interval=year` requests return `annual_unavailable` before creating Stripe
state, and their historical annual prices stay active only for existing
subscriptions. The Pro and Max pricing cards own the billing period, so each
plan's price, checkout link, and CTA analytics (`interval`, `discount_percent`)
always agree.

## Plan switching

Every Max and Pro CTA links `/api/billing/checkout`, and
`web/services/billing/personalSwitchRoute.ts` decides where an existing
subscription goes. The portal route uses the same function for old
`flow=switch_plan` links, so the two never disagree or loop.

- A monthly subscription on a price the switch portal lists
  (`PORTAL_SWITCHABLE_LOOKUP_KEYS`: Pro monthly and both Max intervals) opens
  Stripe's subscription-update flow with the portal configuration stamped
  `metadata.purpose=personal_plan_switch`. The provisioning script creates it;
  the account default configuration stays quantity-only.
- A yearly, grandfathered or Go subscription opens the dashboard's switch dialog
  (`/dashboard/billing?change=max`), which keeps the billing interval and prices
  any subscription.
- An account with no subscription to switch (an operator grant, a company
  account or a legacy Founder purchase) buys Max through a new Checkout.
- The Founder offer is no longer sold. Existing Founder purchases are one-time
  Pro for life, stored as an active Pro row marked `founders_edition`; it is
  never a subscription to switch or cancel. A founder on Max returns to Pro by
  cancelling Max (the dashboard's Pro card opens that cancel dialog), never by
  switching onto a paid Pro price, and `planChange.ts` refuses that switch.

## Changing a price

Stripe amounts are immutable, so a price change mints a new lookup key carrying
the amount and adds the old key to `LEGACY_PRICE_LOOKUP_KEYS`. Grandfathered
Prices (`cmux-go-monthly-10` $10 Go, `cmux-starter-monthly-20` $20, `cmux-pro-monthly` $30, `cmux-pro-yearly` $240, `cmux-pro-yearly-288`
$288, `cmux-team-monthly` $35, `cmux-team-yearly-336` $336,
`cmux-team-yearly-576` $576) stay active for the subscriptions on them, and
`/dashboard/billing` prices every row from its own Stripe amount.

Env price-id overrides carry the amount in their name
(`STRIPE_PRO_MONTHLY_50_PRICE_ID`, `STRIPE_PRO_YEARLY_480_PRICE_ID`,
`STRIPE_MAX_MONTHLY_200_PRICE_ID`, `STRIPE_MAX_YEARLY_1920_PRICE_ID`). A retired
name fails env validation, so delete it from Vercel before deploying a price
change.

## Stripe object ids

| Object | Test mode | Live |
| --- | --- | --- |
| Pro product | `prod_UpIQRE6cj0nFjs` | `prod_Uq4a28vk0fP3E6` |
| Max product | `prod_VOppwEzT7jtBNW` | `prod_VEpRwst8UwD5cm` |
| Max monthly price | `price_1UO29QGhInAdn3JbD2Cld8PX` | `price_1UELmdGhInAdn3Jb8Gpe9ilK` |
| Max annual price | `price_1UOl71GhInAdn3JbYWi9kguZ` | `price_1UOl9ZGhInAdn3Jb8g9BoXSx` |
| Switch portal configuration | `bpc_1UO2AIGhInAdn3JbgNBD6OZD` | `bpc_1UELmeGhInAdn3JbgZqLIbP0` |

`STRIPE_PERSONAL_PLAN_SWITCH_PORTAL_CONFIGURATION_ID` is pinned in Vercel
(production = live id, development and preview = test id) so the restricted
production key never has to list portal configurations. Staging webhook endpoint
`we_1Tq1SZGhInAdn3JbWJReKNEN` forwards to `cmux-staging.vercel.app`; its secrets
are already in the `cmux-staging` Vercel project.

Team billing uses a separate portal configuration pinned by
`STRIPE_TEAM_PORTAL_CONFIGURATION_ID`. Its subscription-update feature is
disabled, while cancellation, invoice history, and payment-method updates stay
enabled. `web/scripts/stripe/provision-catalog.sh <test|live>` creates or updates
that configuration and prints the id to set in the corresponding Vercel
environments.

## Cloud VM allowance

The paid allowance lives in `web/services/vms/machineSpec.ts` and
`web/services/vms/entitlements.ts`.

| Plan | Active VMs | Shared pool | Disk per VM | Largest VM |
| --- | --- | --- | --- | --- |
| Plus (`go`) | 1 saved VM total, paused included | none (one machine) | 128 GB | 8 vCPU / 16 GB (Pro sizes), no monthly hour cap |
| Pro, legacy one-time grants | 5 | 20 vCPU / 40 GB RAM | 128 GB | 8 vCPU / 16 GB (`lg`) |
| Team | 5 per paid seat | 20 vCPU / 40 GB RAM per paid seat, one pool for the team | 128 GB | 8 vCPU / 16 GB (`lg`) |
| Max | 5 | 80 vCPU / 160 GB RAM | 256 GB | 32 vCPU / 64 GB (`2xl`) |

- Team seats multiply by `cmuxSeats`; the pool is shared by every member, not a
  separate allowance per user. The user divides any pool however they like.
- Only `provisioning` and `running` VMs count against the pool; paused and
  stopped VMs do not. Disk is a per-VM limit and is not pooled.
- The largest VM per plan comes from `maxMemoryMbForPlan`. The default machine
  has 8 GB RAM and 32 GB disk.
- The repository enforces the machine count and the pool under the billing-team
  lock on create, Base open/reset, paused resume, resize, and fork, using each
  VM's stored resource reservation. Legacy rows without a marker conservatively
  reserve the provider maximum until reconciliation measures them.
- A request over the pool fails with a typed resource-pool error naming the
  pool, the amount in use, and the request. `GET /api/vm` limits publish the pool
  and its usage. The machine list publishes `lockedMemoryOptionsMb` and
  `memoryUpgradePlanId`, and a create that asks for a locked size gets
  `402 vm_memory_requires_plan` instead of a silently smaller machine.
- Pricing copy must say the resources are pooled, never per VM.
- Env overrides of the active-VM count are retired; the create kill switch
  remains the incident control. Size caps can still be lowered (never raised)
  with `CMUX_VM_PLAN_<PLAN>_MAX_MEMORY_MB`, `CMUX_VM_PAID_MAX_MEMORY_MB` and
  `CMUX_VM_PLAN_<PLAN>_MAX_DISK_MB`.
