# cmux-next paid product: plans, Stripe Checkout, entitlements (design)

Status: BUILDING, 2026-10-21. Stripe TEST mode only. Live mode is the user's money decision
(section 9). Builds on `pricing-DESIGN.md` (numbers), `usage-billing.md` (metering) and
`automations-billing.md` (Workers metering).

User ask (2026-10-21): "Chiefs need to be able to use cmux cli to initiate a stripe link checkout
link thing for users to easily onboard to paid product, which will include cmux VMs, and cmux
coderouter. Check if they're authed in cmux browser, aka if they have stripe link cookies, and if
so, open in cmux browser, else open in their default browser. Build out the paid product fully for
cmux-next."

## 1. Principle: one billing system, not two

cmux.com already sells these plans with Stripe, and classic cmux already has a
`cmux billing checkout` that calls it. cmux-next reuses that path. It does not add a second
Stripe integration in the Cloudflare Worker.

| Piece | Owner (exists today) | Where |
| --- | --- | --- |
| Products, prices, lookup keys | web billing | `web/services/billing/plans.ts`, `stripe.ts` |
| Checkout session (native, signed-in) | web `POST /api/billing/checkout` (Stack bearer + refresh token) | `web/app/api/billing/checkout/route.ts` |
| Webhook to subscription rows | web `/api/stripe/webhook` | `web/services/billing/stripeWebhook.ts` |
| Entitlement record | Stack `client_read_only_metadata.cmuxPlan` (user or team), written by the webhook | `web/services/billing/pro.ts` |
| Entitlement read in cmux-next | `TeamDO.inferencePlan` (cached 10 min, 1 min when unpaid, 2 h stale on Stack outage) | `backend/apps/api/src/inference/plan.ts` |
| Customer portal | web `/api/billing/portal`, `/dashboard/billing` | `web/services/billing/personalPortal.ts`, `teamPortal.ts` |
| Usage meters (AI above included) | Worker `UsageMeterDO` facts, level sync to a metered price | `billing-usage-sync.ts`, `billing-catalog.ts` |
| Prepaid Cloud credits | Worker one-time Checkout, test key only | `credits-checkout.ts` |

New in this change: the cmux-next CLI and app path to the checkout, the Stripe Link check, the
Chief skill, and the Cloud VM entitlement that reads the same plan.

## 2. Plans and what each includes

Numbers from `pricing-DESIGN.md` section 4 (proposal; prices are today's Stripe prices).

| | Free | Pro | Max | Team |
| --- | --- | --- | --- | --- |
| Price | $0 | $50/mo ($40/mo yearly) | $200/mo ($160/mo yearly) | $60/seat/mo |
| Cloud VMs at once | none (`cloud.plan.required`) | 5 | 5 | 5 |
| Largest VM | | 8 vCPU / 16 GB | 32 vCPU / 64 GB | 8 vCPU / 16 GB |
| CodeRouter / model router | free open-model tier (300k tokens/device/day) | paid gate on, included AI usage, then at cost | same, more included | same, per seat |
| Chief credits included / month | $3, hard stop | $25 | $100 | $25/seat pooled |
| Own Claude Code / Codex on your Mac | free | free | free | free |

Plus ($15/mo, plan id `go`, classic #26732, 2026-10-29) is sold by cmux-next too
(`cmux billing checkout --plan plus`): one Cloud machine at Pro sizes, disk up to 128 GB, no hour
cap. Max is five machines (up to 32 vCPU / 64 GB, 256 GB disk), as classic sells it.
`backend/apps/api/test/cloud-plan-classic-parity.test.ts` pins these to classic's
`web/services/vms/entitlements.ts`. Founders (one-time) gets Pro limits.

## 3. Checkout flow

```
Chief / person
  cmux billing checkout --plan pro          (Rust CLI, cmux-tui `cli/billing.rs`)
    -> app socket method billing.checkout   (Swift, `AppControl+Billing.swift`)
       -> POST <cloud.apiBaseURL>/api/billing/checkout {plan, teamId?}
          Authorization: Bearer <Stack access>, X-Stack-Refresh-Token   (CodeRouterClient)
          <- {url, plan, flow: checkout|portal|dashboard|already_active}
       -> Stripe mode of the URL: cs_test_ = test, cs_live_ = live, else unknown
          live + live checkout off -> refuse billing.live_off, open nothing
       -> where to open (section 4) -> LinkRouter.open(url, in: .cmuxBrowser | .system)
    <- {url, plan, flow, mode, opened_in, link_session, reason}
```

- The session is made server-side by web, bound to the signed-in Stack user (personal plans)
  or to a team the caller administers (`--plan team --team ID`). No card data enters cmux.
- `flow: portal`: the person already pays for another plan; web returns a Stripe portal session
  to switch plans. `already_active`: nothing to buy; the URL is the welcome page.
- Stripe Checkout shows Link on its own when the account has Link enabled. We do not build a
  Link button: a person signed in to Link pays with one click on the Checkout page.
- Agent safety: the CLI call reaches the backend as the person's session. Paying always needs
  the person on the Stripe page, so a Chief can start a checkout but cannot buy anything.
  `cloud.billing.checkout` (the catalog op that refuses agent principals) stays unbuilt; the web
  route is the one checkout path.

## 4. cmux browser or default browser (Stripe Link cookies)

Rule (`BillingCheckoutOpener.decide`):

| `--open` | Link session in a cmux browser profile | Result |
| --- | --- | --- |
| `auto` (default) | yes | cmux browser tab |
| `auto` | no | default browser |
| `cmux` | any | cmux browser tab |
| `default` | any | default browser |
| `none` | any | print the URL only |

Default browser is cmux itself, or the cmux browser is off (`browser.enabled`): the cmux tab is
used instead, because `LinkRouter` cannot hand the URL to another app.

"Link session" = an unexpired cookie whose domain is `link.com` or a subdomain of it, in the
profile a new tab of the focused pane would use (`BrowserProfileService.profileForNewTab`).
Only names, domains and expiry are read, never values:

- Chromium profiles: a private copy of `<Chromium root>/Profile-<uuid>/Cookies`, columns
  `host_key`, `has_expires`, `expires_utc` (`SQLiteSnapshot`, as the cookie importer does).
- WebKit profiles: the profile's `WKHTTPCookieStore`.

`checkout.stripe.com` and `m.stripe.com` cookies do not count: any visit to a Checkout page or a
site with Stripe.js sets them, signed in to Link or not.

## 5. Webhooks to entitlements

Unchanged web path: `checkout.session.completed`, `customer.subscription.*` -> `stripe_subscriptions`
-> Stack `cmuxPlan` on the user (go, pro, max, founders) or the team (team). cmux-next reads it:

- Model router / CodeRouter edge: `inference/route.ts` paid gate (exists).
- Cloud VMs: `CloudDO` reads the team's plan through `TeamDO.inferencePlan` before a provider op
  (create, start, resize, snapshot) and on `cloud.plan.get`; `domains/cloud-plan.ts` maps the plan
  id to limits (section 2). The old allowlist stub plan stays for `CLOUD_ALLOWED_TEAMS` in
  development and staging; a paid plan wins over it. Gate: `CLOUD_PLAN_ENTITLEMENTS=on`, set on
  development and staging only. Production keeps today's "no plan" until the user decides
  (section 9).
- A Stack outage keeps the last plan for 2 h, then answers unavailable (retryable), never unpaid.

## 6. Customer portal and status

- `cmux billing status [--team ID]`: `GET /api/billing/plan` (bearer). Plan, billing source,
  team plan, manage URL.
- `cmux billing portal [--team ID]`: opens `<web>/dashboard/billing` (team: `?team=ID`) in the
  same browser rule. The dashboard has the portal button for every billing source (Stripe, Apple,
  Founders), so cmux does not pick one.

## 7. Usage metering

- VM hours: the Cloud machine ledger already has start and stop times. Facts go to the team's
  `UsageMeterDO` as `cloud.vm_seconds` by size, priced at list ($0.045/vCPU-h + $0.0145/GB-h),
  drawn from Chief credits (pricing-DESIGN section 2). Not in this change (a205 owns the merge of VM
  time into the credits ledger).
- CodeRouter / model tokens: exists (`usage-billing.md` S1-S5): facts in `UsageMeterDO`, level sync
  (`last` meter) to a graduated metered price per plan, test mode.

## 8. Chief default behavior

Shipped skill `paid-plans` (`Native/OptChat/optchat-chief/skills/paid-plans/SKILL.md`, written to
`~/.cmux/chief/skills/` at host start). When a task needs a paid feature (`cloud.plan.required`,
an unpaid model-router refusal, out of credits), the Chief:

1. says in one line what the plan adds and its price,
2. runs `cmux billing checkout --plan <plus|pro|max|team> --json`,
3. tells the person where it opened (cmux tab or default browser) and that nothing is charged
   until they pay on the Stripe page,
4. after they pay, checks `cmux billing status --json` and retries the blocked step.

It never asks for card data, never says it bought a plan, and does not start a checkout the person
did not need.

## 9. Live mode (money step, the user decides)

Everything here was tested in Stripe test mode against a test-mode web deployment. Before live:

1. Live checkout from cmux-next: `billing.checkout` refuses a `cs_live_` session (code
   `billing.live_off`, nothing opens) while `BillingLivePolicy.shipped.liveCheckout` is false
   (`Packages/macOS/CmuxNext/Sources/CmuxNextApp/Billing/BillingLivePolicy.swift`). Flipping it is
   one line and lets cmux-next sell the existing live plans (the same products classic sells today).
   It is a build constant, not a hidden setting, so nobody turns it on by accident.
2. `CLOUD_PLAN_ENTITLEMENTS=on` in production: paid users get Cloud VMs at the section 2 limits
   (our Freestyle cost). The production promote holds it until the value is approved in
   `production-approvals.json` (G7) and the provider key secret exists (G5, `prod-promote.ts`), and
   `test/cloud-plan-production.test.ts` refuses it while production has no Cloud image.
3. The included amounts of section 2 replace the test placeholders in `billing-catalog.ts`
   (`pricing-DESIGN.md` section 9 decisions).
4. Stripe Link on the live account: Dashboard > Settings > Payment methods > Link. In test mode the
   default payment method configuration has Link `on` (read 2026-10-21).
5. Product text: the Stripe Pro product says "5 Cloud VMs with 4 vCPUs and 8 GB RAM each" (the
   classic entitlement); cmux-next Pro allows up to 8 vCPU / 16 GB. Align one of them before live.

## 10. Tests

- Rust (`cmux-tui` `cli/billing/tests.rs`): verb and option parsing, plan validation, params sent.
- Swift (`CmuxNextAppTests/BillingCheckoutTests.swift`): Link cookie match, open decision table,
  Stripe mode of a URL, live refusal.
- Worker (`backend/apps/api/test/cloud-plan-entitlements.test.ts`): plan -> limits, flag off
  keeps today's behavior.
