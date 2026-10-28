# cmux-next paid plans: pricing, upgrade, onboarding, dashboard (design)

Status: BUILDING, 2026-10-27. Stripe TEST MODE and staging only. No live prices, no real charges.
User ask (Lawrence, 2026-10-27): "we need to work on paid plans + onboarding to paid plan + dashboard
for paid plans etc".

This note builds on `paid-plan.md` (money plumbing: credits, router, overage) and
`pricing-DESIGN.md` (numbers). It audits the path a person walks, end to end, and names the gaps.

## 1. Audit (origin/feat-cmux-next at 1e38b841c95)

| Step | Where | State |
| --- | --- | --- |
| Plans and prices | `pricing-DESIGN.md` §4; `web/services/billing/chiefPricing.ts`; `/next/pricing` (preview flag, noindex) | Proposal: Free 0, Pro 50, Max 200, Team 60/seat. Live cmux.com plans are classic (Go/Pro/Max/Team, web `plans.ts`). `billing-catalog.ts` still has included 5/20/100/20, `paid-plan.md` §1 says 3/25/100/25. |
| Checkout (subscription) | cmux.com `POST /api/billing/checkout` (native, Stack bearer), `GET /api/billing/checkout?plan=` (web) | Built, live code for classic plans. Accepts `cmux_scheme` so the success page's "Open cmux" link returns to the right app. |
| Checkout (Chief upsell) | Worker `GET /v1/billing/plan/<signed link>` (`plan-checkout.ts`) | Test mode only, inline `price_data`. **A paid test session grants nothing** (the plan comes from web billing's Stack `cmuxPlan`). |
| Prepaid credits | Worker `/v1/credits`, `/v1/credits/topup`, webhook (`credits-routes.ts`) | Built, test key only. Balance, 30-day per-Chief spend, last 20 entries. |
| CLI | `cmux billing checkout|portal|status` (`AppControl+Billing.swift`) | Built. Sends no `cmux_scheme`, so a cmux NEXT checkout returns to classic `cmux://`. `billing.portal` builds the URL from the Cloud API base, not cmux.com. |
| In-app paywalls | (a) Cloud create plan gate (sidebar card, `CloudPresenter.confirmCreate`), (b) Cloud server refusal dialog (`CloudPresenter.offerPro`), (c) palette "Upgrade to cmux Pro" (`UpgradeToPro`), (d) inference 402 `inference.plan_required` | (a)-(c) each open `https://cmux.com/pricing` on their own (three copies). None uses the native checkout the CLI has, none comes back to the app, nothing refreshes the plan after payment. (d) has no app surface. |
| Post-payment onboarding | cmux.com `/billing/success` (feature cards, "Open cmux"), `/app-pro-welcome` (classic app) | Web only. cmux NEXT shows nothing when the plan turns paid; the Cloud gate keeps the old limits until the next list refresh. |
| Billing dashboard | cmux.com `/dashboard/billing` (plan, change, cancel, resume, seats, Stripe portal for card and invoices) | Built for classic billing. Shows no cmux-next usage: no included amount used, no credits balance, no Cloud time. |
| cmux-next console | console(-staging).cmux.dev (`backend/apps/dashboard`) | Team AI limits view (`-ai-spending.tsx`, billing.manage only). **No billing page**: no plan, no credits, no upgrade, no portal link. |
| Usage data | `teamUsageLine` (team-ai-usage.ts), `makeCredits().balance`, TeamDO `inferencePlan` | Built in the Worker; only `team.ai_limit.get` (admins) reads the usage line. |

## 2. Gaps, ranked

1. **One upgrade path from every paywall (app).** Four paywalls, three copies of "open pricing".
   Shared behavior policy: one action. Default picked: every paywall calls `PaidPlanUpgrade.start`,
   which asks cmux.com for a native Checkout session (the CLI's `billing.checkout` body plus this
   app's `cmux_scheme`) and opens it; signed out, or the server refuses, it opens the refusal's link or
   pricing. It records a pending upgrade so the app refreshes the plan when it becomes active again.
2. **Paid-plan onboarding step (app).** Default picked: when the plan the app reads turns paid after a
   pending upgrade, one sidebar card "Welcome to cmux Pro" shows once per account and plan, with the
   next step (start a Cloud machine) and a link to the billing page. No card for a plan the person
   already had.
3. **A billing page on the cmux-next console.** Default picked: `/billing` on console(-staging).cmux.dev
   reads one new Worker route, `GET /v1/billing/summary`: plan, included amount used this period,
   credits balance and recent entries, upgrade links (test mode), credit top-up, and "Manage billing"
   (cmux.com `/dashboard/billing`, where the Stripe portal holds card, invoices and cancel).
4. **CLI return scheme.** `billing.checkout` sends this app's `cmux_scheme` (falls out of gap 1).
5. **Test plan grant (later).** A paid test-mode upsell session grants no plan. Needs a decision on who
   owns the grant (web `cmuxPlan` vs the Worker's plan copy); out of scope here, kept in §5.
6. **Inference 402 card in the composer (later).** `paid-plan.md` §4 owns it; it reuses
   `PaidPlanUpgrade` for its "See plans" action.
7. **Invoices inside cmux (later).** The Stripe portal lists them; a native list waits for the plan
   grant (5), since the Worker holds no subscription customer yet.

## 3. Interfaces

`GET /v1/billing/summary` (signed in, read; team = caller's current team, `x-cmux-team` picks one):

```json
{ "ok": true, "value": {
  "team": "team_…", "personal": true,
  "plan": { "id": "pro" | null, "name": "cmux Pro" | "Free", "paid": true },
  "usage": { "included_usd": 20, "spent_usd": 3.2, "period_start": 0, "period_end": 0, "billed": false, "stopped": false } | null,
  "credits": { "available_usd": 10, "balance_usd": 10, "held_usd": 0, "entries": [], "topup_amounts_usd": [10,20,50,100] } | null,
  "upgrade": [{ "id": "pro", "name": "cmux Pro", "usd": 50, "checkout_url": "…/v1/billing/plan/<signed>" | null }],
  "manage_url": "https://cmux.com/dashboard/billing", "pricing_url": "https://cmux.com/pricing",
  "test_mode": true } }
```

`plan.paid` is false and `plan.id` null on an unavailable plan service only when `plan_unavailable`
is true (never reported as "unpaid"). `upgrade` lists only plans above the current one.

App: `PaidPlanUpgrade` (CmuxNextApp/Billing): `start(plan:source:fallback:)` returns
`.checkout(URL)` or `.pricing(URL)` for tests; `PaidPlanOnboarding` decides the one-time welcome from
(pending upgrade, previous plan, new plan), persisted in an injected `UserDefaults`.

## 4. Steps (failing test first)

1. Worker `GET /v1/billing/summary` (vitest, fake Stripe off).
2. Console `/billing` page on it; deploy staging; screenshot.
3. App `PaidPlanUpgrade` and its wiring into the four paywalls; `billing.checkout` sends `cmux_scheme`.
4. App `PaidPlanOnboarding` and its sidebar card; refresh on activation while an upgrade is pending.

## 5. Needs Lawrence

- Final prices and included amounts (catalog 5/20/100/20 vs proposal 3/25/100/25).
- Live Stripe keys and real charges (code refuses live keys).
- Who grants a plan bought through the Worker's upsell link (gap 5): web `cmuxPlan` (default) or the Worker.

## 6. Prepaid credits v2: any amount, auto-reload, Claude billing parity (user, 2026-10-27, msg 14648)

Ask: "prepaid credits, so a person can add any amount they want, not fixed packs (set a min/max), and
configurable auto-reload (a threshold, a reload amount and a monthly cap). Study how Anthropic/Claude
bills ... and reach parity across all those methods."

### 6.1 How Claude bills (read 2026-10-27, Anthropic help center)

| Claude method | What it does | cmux today | Plan |
| --- | --- | --- | --- |
| Prepaid API credits (Console) | Buy credits up front; a receipt per purchase | Packs 10/20/50/100 only (`/v1/credits/topup`) | **Any amount** between a min and a max (§6.2) |
| Auto-reload (Console; also "usage credits" on Pro/Max/Team) | When the balance reaches a threshold, buy more; turning it on below the threshold buys at once; card only, not ACH | None | **Auto-reload** with threshold, reload amount, **monthly cap** (§6.3) |
| Subscriptions (Pro, Max, Team seats) | Monthly plan, included usage | cmux.com Go/Pro/Max/Team (web billing) | Exists; console page shows it (§1) |
| Monthly included credits, spent before purchased credits, expire each cycle | Max/Team API credits | Included amount per plan (`billing-catalog.ts`), then postpaid overage | Exists (usage-billing.md); order "included first, then purchased" kept |
| Usage-based billing / invoicing in arrears (Enterprise, via Sales) | Monthly Stripe invoice for usage, net terms | Postpaid metered overage on the plan subscription (`billing-usage-sync.ts`) | Exists for plan holders; contract invoicing with net terms is a Sales step (needs Lawrence: terms, who approves) |
| Spend limits (org cap by usage tier; workspace limits) | Monthly cap; slightly over is possible since the check is before the call | Team AI limit per member (`team.ai_limit`), automation cap (`usage.cap.set`), provider daily brake | Exists; auto-reload's monthly cap bounds automatic charges (§6.3) |
| Invoices and receipts in the Console | Admin/Billing roles read them | Stripe portal via cmux.com `/dashboard/billing`; credits ledger on the console | Exists; native invoice list later (gap 7) |

Sources: support.claude.com articles 8977456 (paying for API usage), 12429409 and 12005970 (usage
credits, auto-reload), 11526368 (Enterprise billing), 16608069 (API invoices), 17154008 (monthly
API credits), docs rate limits (tier spend caps).

### 6.2 Any amount

- `POST /v1/credits/topup {"usd": 37.5}`: any amount with at most 2 decimals in
  `[CREDITS_TOPUP_MIN_USD, CREDITS_TOPUP_MAX_USD]`, defaults **5** and **2,500** (Claude's Console minimum
  is 5 USD). The old packs stay as suggestions (`amounts_usd`). The signed link (`?usd=`) takes the same range.
- `GET /v1/credits` and `GET /v1/billing/summary` answer `topup_min_usd` and `topup_max_usd`.
- Console: an amount field next to the suggestion buttons.

### 6.3 Auto-reload

- Settings per team, in the team's UsageMeterDO: `enabled`, `threshold_usd` (reload when available credit
  falls below it), `amount_usd` (each reload; in the top-up range), `monthly_cap_usd` (the most auto-reload
  charges in a UTC month; at least one reload). Default picked: a fixed reload amount (the user's words),
  not Claude's "bring the balance back up to".
- `GET /v1/credits/auto-reload` (member), `PUT /v1/credits/auto-reload` (member; same rule as top-up:
  anyone in the team may pay into it). Turning it on needs a saved card on the team's payment customer
  (`credits.no_saved_card` with the top-up path otherwise). Top-ups now save the card for off-session use
  (`setup_future_usage=off_session`), so the first top-up is the setup.
- Trigger: after a credits charge settles, the DO checks `available < threshold`, `month total + amount <=
  cap`, and no reload in flight; then charges the saved card off-session (Stripe PaymentIntent, `confirm`,
  `off_session`, idempotency key per team, month and reload number). Turning it on while already below the
  threshold reloads at once (as Claude). A success adds credits once (`autoreload:<payment intent>`); the
  webhook (`payment_intent.succeeded`, kind `cmux_credits_autoreload`) grants the same key, so a lost answer
  still grants once. A refused card turns auto-reload off with the reason shown, so a bad card is never
  retried on every call.
- Test mode only (`creditsKey` refuses live keys and test keys on production).

### 6.4 Steps (failing test first)

1. Any amount (Worker): range checks, summary fields. 2. Auto-reload settings route and decision. 3. The
off-session charge, grant, cap, in-flight guard, card-refused turn-off, webhook grant. 4. Console: amount
field and auto-reload form. 5. Staging: a test card top-up of a custom amount and one auto-reload.
