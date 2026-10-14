# Usage billing for AI spend (billable facts) — design note, step 1

Bead: cx-y79zh (P1). Base read: origin/feat-cmux-next at bc24e6885fff.

## Decisions (2026-10-13)

- Lawrence (through the chief): pricing is PASS-THROUGH. Usage above each plan's included amount is
  billed at exactly our provider cost (multiplier 1.0, no margin). `price_version` stays, so a later
  change is a new version. Included amounts per plan are placeholders in test mode; Lawrence sets the
  real numbers before live.
- Lawrence: Founders and Apple buyers get a hard stop at the included amount; no card path.
- Lane lead: the pusher is a web cron with the existing Stripe key (the Worker holds no Stripe key);
  member limits stay per UTC month and the bill uses the Stripe period; an expired reservation is
  billed at the reserved amount and a late settle writes a correction fact.
- Order: S1 (metering fixes, feat-cmux-next) and S0 (plan item, web on main, PR with the chief's go
  before merge) first; Stripe test mode only after both; no live objects, prices or keys.

S1 landed on feat-cmux-next: `UsageMeterDO.settleCall` (`backend/apps/api/src/usage-user.ts`) writes
the call's fact and every counter in one transaction, on the charged path too; the proof is
`backend/apps/api/test/inference-spend-facts.test.ts` at the route.

S2 (period levels, billable fact retention): money facts are kept 400 days, count-meter dedupe keys
35 days; `POST /v1/internal/billing/levels` (BILLING_LEVELS_KEY) and `UsageMeterDO.level` sum the
facts by `recorded_at` in [from, to). Decision (S2 review P2-2): the bill's period is the fact's
recording time, not its `month` column. A call reserved at 23:59 on the last day of a month and
settled (or expired) after midnight counts in the old UTC month for the member limit and in the
new billing period on the invoice. A closed period's level never changes after the period ends. The
daily counter check compares `user_month`/`usage_month` with facts grouped by the `month` column.

Placement (lane lead 2026-10-13, after Lawrence's "no main merge without his yes"): the pusher is in
the cmux-next API Worker (option a), with its own test-mode Stripe key; it reads the team link from
Stripe subscription metadata (stackTeamId / stackUserId) and needs no web database or main change.

Live decisions for Lawrence (add to the live step list):
- Team included amount: per team or per seat (per seat means the pusher subtracts it and the price is flat).

Support note (S1 behavior change): the team cap now counts charged failures (the provider may have
billed, so the full reservation is charged) and expired reservations (a call that never settled is
charged at its reserved amount, and corrected if the real cost arrives later). Before S1 the team cap
missed both. A team near its cap can therefore stop a little earlier than before; support can explain
it that way: "calls that failed after the provider may have charged us count toward the cap".

S0 landed on main as 370c51e40177 (PR 20210): web reads the plan item (`planItem`, never a metered
item) for seats, plan, price, period and the MRR SQL. Read-only check on cmux-prod main (reader role,
replica, 2026-10-13): 781 subscription rows, 0 rows with more than one item, 0 rows where the old and
new item rule differ, the same unit-amount sum before and after.
Pattern: https://blog.exe.dev/billable-facts ("Stripe just wants a number"): product code records
facts; a reconcile worker computes the number and pushes it to Stripe. The post does not cover
idempotency, meters, corrections or failure handling; those parts below are ours.

## 0. What exists today (read from the code)

- Model router: `backend/apps/api/src/inference/route.ts`. Per call: `UsageMeterDO.check` (team cap),
  `UsageMeterDO.reserveUser` (member limit, max cost), `SpendGuardDO.plan` (global provider daily cap),
  upstream call, then in `onDone` three separate writes: `SpendGuardDO.settle`, `UsageMeterDO.settleUser`
  (user_month), `UsageMeterDO.record` (`inference:<id>`, meter `model.spend_usd`, no user).
- `backend/apps/api/src/usage-meter-do.ts`: `usage_ledger` (keyed, idempotent, PRUNED after 35 days),
  `usage_month` (team counter per UTC month, integer micros for money meters),
  `backend/apps/api/src/usage-user.ts`: `user_month` (per member, REAL micros), `user_reservation`.
- `backend/apps/api/src/inference/spend-guard-do.ts`: our own provider-cost brake per budget line per
  UTC day. Not customer money.
- Limits: `backend/apps/api/src/domains/team-ai-limit.ts` (`team.ai_limit.*`, default 200 USD per member
  per UTC month, `INFERENCE_USER_MONTHLY_DEFAULT_USD` in `backend/packages/protocol/src/team-ai-limit-ops.ts`).
- Automation meters: `COST_USD_PER_UNIT` in `backend/apps/api/src/domains/usage.ts` = Cloudflare cost
  rates, "prices to customers come later" (`plans/cmux-next/automations-billing.md` 5.3 already
  proposed hourly sum meter events keyed `team:meter:hour`; this note replaces that with level sync).
- Paid gate: `backend/apps/api/src/inference/plan.ts` reads `client_read_only_metadata.cmuxPlan`
  from the sign-in service (team: `team`; personal: `go|pro|max|founders`,
  `backend/packages/protocol/src/inference-plans.ts`), written by web billing
  (`web/services/billing/pro.ts`, `PAID_PLAN_IDS`).
- Web Stripe: `web/services/billing/stripe.ts` (API `2026-06-24.dahlia`, stripe 22.3.0), tables
  `stripe_customers`, `stripe_subscriptions`, `stripe_webhook_events`, `team_seat_reconciles`
  (`web/db/schema.ts`, cmux-prod Postgres), webhook `web/app/api/stripe/webhook/route.ts`, seat
  reconcile (already the billable-facts shape: dirty flag + try-lock + level) in
  `web/services/billing/teamSeats.ts` + `teamSeatQueue.ts`, cron `/api/cron/team-seats`,
  `/api/cron/billing-reconcile` (`web/vercel.json`).
- Prices: `web/services/billing/plans.ts` (Go 10, Pro 50/480y, Max 200, Team 60/seat; lookup keys
  carry the amount). Founders = one-time purchase (no subscription). Apple purchases = no Stripe
  subscription. No `automatic_tax` anywhere in web: Stripe Tax is OFF.
- Team id mapping is a pure function (`backend/apps/api/src/domains/user.ts`):
  shared team = `stackTeamIdFor(STACK_PROJECT_ID, stack_team_id)`, personal team =
  `personalTeamIdFor(userIdFor(STACK_PROJECT_ID, stack_user_id))`.

### Defects found (they matter before any money moves)

1. route.ts `outcome.kind === "charged"` (provider may have billed): `settleMember(maxMicros)` runs,
   `meter.record` does not. The member counter and the team counter disagree; the team bill would miss it.
2. One AI call = three independent RPC writes. A failure between them leaves the counters different.
3. `usage_ledger` rows are deleted after 35 days and carry no user. It is a dedupe table, not a fact record.
4. `user_month.usd_micros` is REAL (float). Money for billing must be integers.
5. Ten web call sites read `subscription.items.data[0]` as THE plan item (`teamSeats.ts:164,172`,
   `planChange.ts:96`, `purchase.ts:3349,3353,3358`, `reconcile.ts:187`, `subscriptionPlan.ts:10`,
   `services/vms/goUsage.ts:33`, `services/analytics/stripeBilling.ts:227`). A second (metered) item
   on the subscription would break seats, plan labels and period reads. Must be fixed first.
6. Money exposure today: every paid plan, including Go at 10 USD, lets each member spend up to
   200 USD of our provider cost per month, unbilled. Pricing pages say nothing about AI.

## 1. What is billed (MONEY DECISION for Lawrence)

Options:

- A. Pass-through provider cost. Simple and honest. We lose money on every overage dollar
  (card fees about 3 percent plus Stripe Billing usage fee), and refunds and failed calls cost us.
- B. Provider cost times one published multiplier (example 1.2), price version recorded on each fact.
  One number to explain ("AI usage at cost plus 20 percent"); margin changes apply forward only.
- C. A per-model token price list. Matches competitors' pages, but every model and provider change
  is a price change, and the router can serve one model from providers with different costs.

Inclusion options: (i) always billed from the first cent; (ii) an included amount per plan, then
billed above it, still under the member and team limits; (iii) included only, hard stop, no overage.

RECOMMENDED: B with (ii). DECIDED by Lawrence: A (pass-through) with (ii). The fact keeps our cost and the list price (cost x multiplier of the price
version). Included amount per plan is a Stripe graduated tier (first N USD at 0, then 1.00 USD per
unit). Proposal numbers to replace: Go 5, Pro 20, Max 100, Team 20 per seat, multiplier 1.2.
Strongest objection: an included allowance on a 10 USD plan can cost more than the plan earns;
answer: the allowance is a Lawrence number, and the 200 USD member default should drop to the
included amount for Go until a card-backed overage is on.

Stripe objects (RECOMMEND):
- One Billing Meter `cmux_ai_usage`, aggregation `last`, value = the period's billed USD so far
  (decimals are accepted). `last` makes Stripe hold a level, not a sum of deltas: repeating a push
  cannot double bill.
- One Product "cmux AI usage" and one metered Price per plan (graduated tiers carry the included
  amount), lookup keys with the amounts in them, made by `web/scripts/stripe/provision-catalog.sh`.
- The metered Price is a second item on the existing go/pro/max/team subscription (one invoice, one
  period). Not invoice items: they give no live preview and need our own included-amount math.
- Founders and Apple customers have no Stripe subscription: options are (iii) hard stop at an
  included amount, or a usage-only Stripe subscription (0 USD base + the metered price) after they add
  a card. RECOMMEND (iii) first, usage-only subscription later. MONEY DECISION.
- Automation meters: record facts at price 0 now (same table, same pipeline); prices later.

## 2. The fact table

Where: in each team's `UsageMeterDO` SQLite (`backend/apps/api/src/usage-meter-do.ts`), next to
`user_month`. It is already the single writer per team, it is in the request path for limits, and a
fact plus its counter update fit in one `transactionSync`. Web Postgres is wrong for the write: an
inference request would write across systems. A projection of facts to the cmux-next PlanetScale
database (existing outbox) is for finance queries and audit only, never the source.

Change: `usage_ledger` becomes the fact table (no second table): add columns, keep rows (no 35-day
prune for billable rows; keep at least 18 months), integer money.

| column | meaning |
| --- | --- |
| `key` TEXT PK | fact id: `inference:<call id>`, `tail:...`, `step:<run>:<step>`, `corr:<id>` |
| `team` | implicit (one DO per team), stored for the projection |
| `user` | the member it counts against (`unattributed` for old runs) |
| `at` INTEGER | recording time (ms), Worker clock; decides the period |
| `month` | UTC month of `at` (the limit window) |
| `meter`, `quantity` | as today (integer for count meters) |
| `cost_micros` INTEGER | our cost |
| `price_micros` INTEGER | billed list price at `price_version` (0 = included or not billed) |
| `price_version` | e.g. `ai-2026-10-v1` |
| `source` | tail, step, egress, capability, scheduler, coderouter, reservation_expired, correction |
| `corrects` TEXT NULL, `reason` TEXT NULL | set on a correction |

Writes:
- Settled AI call: one new DO method `settleCall(entity, id, user, costMicros)` replaces
  `settleUser` + `record`: one transaction deletes the reservation, `INSERT OR IGNORE` the fact
  `inference:<id>`, adds to `user_month` and `usage_month`. Used by the normal and the `charged` path
  (fixes defects 1 and 2). `SpendGuardDO.settle` stays separate (our brake, not the bill).
- Reservation never settled: the alarm writes fact `inference:<id>` source `reservation_expired` at
  the reserved amount (as the limit already does). A late settle writes `inference:<id>:late` with the
  difference (negative) and `corrects = inference:<id>`.
- Metered automation step: `record()` as today, one fact per record key, now with cost and price.
- Correction or refund: new staff op `usage.fact.correct` (risk money, audit) writes `corr:<uuid>`
  with a signed amount and `corrects`. Nothing is updated or deleted. Money already paid on a
  finalized invoice is returned by a Stripe credit note from web, and the matching fact is recorded too.

## 3. The reconcile worker

RECOMMEND: a web cron `/api/cron/usage-sync` every 10 minutes, plus a final run per subscription
from the `invoice.created` webhook. Reason: web already holds the Stripe key, customers,
subscriptions, test/live separation and the seat-reconcile pattern; the Worker stays free of Stripe
keys. Option rejected for now: a cron on the cmux-next API Worker with its own Stripe key (two key
holders, and the Worker cannot read `stripe_customers`). The fact side does not change if the pusher
moves into the Worker later.

Backend half: a read-only service op `billing.usage.levels` on the API Worker (service principal,
not a user session): input a list of `{stack_team_id | stack_user_id, from, to}`; the Worker maps the
Stack ids to team ids itself (one implementation of the hash) and returns per item
`{price_micros, cost_micros, facts, last_at, digest}` = `SUM` over facts with `from <= at < to`.
The window is the Stripe subscription period (anniversary dates), not the UTC month.

Web half, per active metered subscription (work list = `stripe_subscriptions`, small):
1. Try-lock per customer (same advisory lock as seats; Stripe allows one concurrent meter call per
   customer per meter).
2. Read the level for `[current_period_start, current_period_end)`.
3. Skip when `level == last_pushed` in a new `usage_sync` row
   (`subscription_id, period_start, last_pushed_micros, pushed_at, stripe_seen_micros, last_error`).
4. Else create a meter event: value = level USD, timestamp = min(now, period_end - 1 s),
   identifier = `ai:<subscription>:<period_start>:<level_micros>` (a retry of the same level is
   the same identifier; a repeat is harmless anyway with `last`).
5. Record the outcome; an error keeps the row dirty for the next run.

Stripe down: nothing is lost. Facts keep accruing; the next run sends the newest level. Retries:
next cron pass, exponential backoff on 429. Alert when a subscription has not synced for 2 hours.
Backend down: no level read, no push, same retry.
Period close: set an invoice finalization grace period in Stripe (UNVERIFIED value, for example 24 h;
a Billing setting, needs Lawrence) and run the final push on `invoice.created`. If a closed period's
level is still above the pushed value after finalization, the worker writes a carry-over fact into the
current period (`carry:<subscription>:<period_start>`), never a second charge for the old one.
Drift report: after each push read the meter event summary for the period and compare with the level;
alert (error tracking + log) when they differ by more than 0.01 USD for over one hour. Daily: the DO
alarm recomputes `user_month`/`usage_month` from facts and logs any mismatch; cost facts vs
`SpendGuardDO` spend vs the provider bill.

## 4. Team to Stripe link

No new mapping table. Web owns Stripe customer and subscription (`stripe_customers.stack_team_id` or
`stack_user_id`, cmux-prod). The backend owns teams and facts. The join key is the Stack id, and the
team id is a pure hash of it (section 0); the backend does the hashing in `billing.usage.levels`.
Condition: web and Worker use the same Stack project per environment (dev and staging Workers use
454ecd03..., production uses 9790718f...; verify web production uses the same).
Webhook path for subscription changes: Stripe -> `web/app/api/stripe/webhook/route.ts` ->
`stripe_subscriptions` + `cmuxPlan` metadata -> sign-in service team webhook -> cmux-next
`stack-webhook.ts` -> TeamDO plan copy (`inference/plan.ts`), as today. New in web: on
`customer.subscription.created/updated` mark the subscription for the reconcile worker to ensure the
correct metered item (added on a new paid subscription, price swapped on go/pro/max change); on
`invoice.created` mark it for the final push. The webhook itself makes no Stripe calls.

## 5. Limits and the bill read the same facts

The member limit and team cap read `user_month`/`usage_month`, which are caches written in the same
transaction as each fact and rebuilt from facts by the daily check. The bill is `SUM(price_micros)`
over the same rows. Limits move from cost to billed price (what the customer sees), so a member limit
of 50 USD means 50 USD on the invoice. `SpendGuardDO` stays a cost brake for us and is not a bill input.
Window decision: limits stay per UTC month (they already say "resets on the 1st"); the bill uses the
subscription period. Both are sums over the same facts, so no second counter. Alternative: move limits to
the billing period too (cleaner copy, needs the period in TeamDO).

## 6. What the user sees

- Console team page, AI spending section (`backend/apps/dashboard/src/routes/-ai-spending.tsx`):
  "AI usage this billing period: 12.34 USD of 20.00 USD included", then "Above the included amount,
  usage is added to your next invoice." Admins see per member usage. Read from a new
  `billing.usage.get` (or `team.ai_limit.get` grows period, included and usage fields).
- Web billing screen (`web/dashboard-app/screens/billing/billing-screen.tsx`): the upcoming invoice
  line.
- Invoice line: product "cmux AI usage", quantity in USD, for example "cmux AI usage, 32.50 x 1.00 USD,
  first 20.00 included". No provider or vendor names in cmux copy.

## 7. Risks

- Double billing: `last` meter + level values + stable identifiers; one fact per call id
  (`INSERT OR IGNORE`); one item per subscription checked before adding.
- Missed billing: defect 1; push failures (alert at 2 h); period close (grace period + final push +
  carry-over fact); Apple and Founders customers have no subscription (decision).
- Period boundary: facts carry `at`; Stripe periods are not UTC months; a test-clock test covers it.
- Currency: USD only; all prices USD.
- Tax: Stripe Tax is off (no `automatic_tax`). Usage lines follow the subscription's tax settings.
  Turning it on is Lawrence's decision.
- Test vs live: the Worker never holds a Stripe key; web test key only on the dev backend; meter
  and price ids per mode by lookup key; refuse a `sk_live` key outside production web.
- Existing subscribers: adding a metered item changes what they may pay. Terms and customer notice
  are a legal and money decision.
- Stripe limits: meter event 1000/s live, sandbox counts toward the global limit; we send at most one
  event per subscription per run.
- Corrections: Stripe can cancel a meter event only within 24 h; we never use that path (levels).

End-to-end test in Stripe test mode: dev Worker `cmux-api-development` (test team on
`INFERENCE_ALLOWED_TEAMS`) and the shared dev web stack with the Stripe test key. Note: the pusher is
in web, so "dev Worker only" is not enough; the dev web stack is the second half. Steps: a Stripe test
clock customer with a Pro subscription and the metered item; real model calls through the dev
Worker; run `/api/cron/usage-sync`; check the meter summary equals `billing.usage.levels`; run it
again (no new event); make Stripe unreachable for one run, then recover; add a correction fact; advance
the test clock past period end; check the finalized invoice line = level minus included. bun runs on a
Freestyle VM, never the laptop.

## 8. Slice plan (behavior tests at real boundaries, no unit tests)

| slice | change | proof | needs Lawrence |
| --- | --- | --- | --- |
| S0 | web: find the plan item by price, not `items.data[0]` (10 sites) | webhook + seat reconcile on a test-mode subscription with two items | no |
| S1 | backend facts: `settleCall`, charged-path fix, ledger columns, no prune, integer money, `usage.fact.correct`, daily rebuild check | dev Worker: real calls, `team.ai_limit.get` spend equals fact sum; settle failure cases | no |
| S2 | `billing.usage.levels` service op | curl on dev Worker with Stack ids, window sums | no |
| S3 | test-mode meter, product, graduated prices via `provision-catalog.sh` | Stripe test mode objects by lookup key | numbers (multiplier, included per plan) can be placeholders in test mode |
| S4 | web `usage-sync` cron, `usage_sync` table (migration rehearsed on staging branch), metered item ensure, `invoice.created` final push, drift alert | the test-clock run in section 7 | no (test mode) |
| S5 | console and web billing UI copy | tagged dashboard proof | copy review if wanted |
| S6 | live: prices, live meter, grace period, tax, customer notice, add item to existing subscriptions | live dry run on one staff account | yes: all of it |

## 9. Test-mode end-to-end result (2026-10-13)

Development Worker (`BILLING_USAGE_PRICE_SET=e2e`, 1 USD included), Stripe test mode, test clocks,
agent account CMUX_UITEST (dev sign-in project; `cmuxPlan=pro` set on the dev project only), its
personal team `team_6774f37212cb1152d2a9` (already on the development `INFERENCE_ALLOWED_TEAMS`; no
allowlist change was needed). Script: `backend/scripts/stripe-usage-e2e.ts`.

- Run 2 (clock `clock_1UQ0yHLbtiW1udY8ynqwKD6e`, subscription `sub_1UQ0yILbtiW1udY8B1cT9rDS`):
  27 real model calls; the sync added the usage item once and sent each new level once (a repeat run
  sent nothing). Usage written with the clock 10 minutes before the period end, and usage written after
  the renewal while the invoice was a draft, both reached the finalized invoice. Level 1.350535 USD;
  the renewal invoice: Pro 50.00 + "0.350535 x cmux AI usage (Tier 2 at $1.00)" = 0.35, total
  50.35 USD, correct to the cent; the meter summary matched the level exactly.
- Run 1 finding: a level sent about one minute before the invoice finalized did not reach it (the
  invoice used the level before it; the meter summary showed the newer one later). Stripe aggregated
  meter events in 45-50 s in run 2. In live mode Stripe keeps a subscription invoice a draft for about
  an hour after the period ends, and the sync runs every 15 minutes, so only usage in the last minute
  or so before finalization can slip; a finalization grace period (live step) covers it. The webhook
  would not fix an aggregation delay, so it stays a live step.
- Cleanup: both subscriptions canceled, both test clocks deleted by exact id, Freestyle VMs deleted.
  The development `BILLING_USAGE_PRICE_SET=e2e` stays as the standing billing-e2e configuration
  (test mode only; staging and production ignore it). Staging must never get STRIPE_USAGE_KEY while it
  shares the development Stripe sandbox; a separate sandbox is needed if staging ever pushes.

## 10. Live steps for Lawrence (none done; all test-mode work above)

1. Restricted live key (Stripe Dashboard only): Billing meter events Write, Subscriptions Read,
   Subscription items Write, Prices Read, Customers Read. Store it in the team store; it goes to the
   production Worker as STRIPE_USAGE_KEY. The code refuses every live key today: the live switch is
   a reviewed code change (an explicit production allow) landed with the key.
2. Real included amounts per plan (go, pro, max, team) and the answer to "Team included amount: per
   team or per seat" (per seat means the pusher subtracts it and the price is flat).
3. Live catalog: the meter `cmux_ai_usage` (aggregation last), the product "cmux AI usage" and one
   graduated price per plan with the real amounts (a new `-v2` price set), made by the catalog script
   with a live switch it does not have today.
4. Reconcile on live subscriptions: the sync adds the usage item to every active monthly go, pro, max
   and team subscription. Decide the order: staff accounts first, then everyone; annual plans are
   skipped (they cannot hold a monthly metered item).
5. Invoice finalization grace period (Stripe Billing settings), for example 1 to 24 hours, and the
   `invoice.created` webhook to the Worker for a final push per subscription.
6. Stripe Tax (off today) for the usage lines.
7. Customer notice and terms: AI usage above the included amount is billed at our provider cost; the
   pricing page and the console say so before the first live invoice.
8. Founders and Apple buyers: hard stop at the included amount (decided); the limit code for it is
   still to build (S5).
9. Rotate the development and staging BILLING_LEVELS_KEY / STRIPE_USAGE_KEY secrets onto the team
   Cloudflare token when it exists (they were set with Lawrence's own OAuth login).
