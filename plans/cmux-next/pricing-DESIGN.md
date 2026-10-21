# cmux-next pricing: Chief, tokens and sandboxes (design, proposal)

Status: PROPOSAL, 2026-10-19. Nothing here is for sale. No Stripe Product or Price was
created and the page is not on the production site. The user approves the numbers in
section 9 first.

- Code: `web/services/billing/chiefPricing.ts` (tier data, rates, calculator math),
  `web/app/[locale]/(landing)/next/pricing/` (page + calculator),
  tests `web/tests/chief-pricing.test.ts`, `web/tests/chief-pricing-calculator.test.tsx`.
- Gallery: `plans/cmux-next/pricing-gallery/index.html` (variants A-D of the page, E-G in-app).
- The page renders only outside Vercel production (`isNextPricingPreviewEnabled`), is
  `noindex`, and its paid buttons link to today's `/pricing`.

User ask (2026-10-19): "incorporate how we price Chief into everything ... Chief is going to
be the killer feature that people will pay for ... usage-based tokens with Chief, with an
included baseline, with open-source models. Also Chief can start sandboxes now."

## 1. What exists today (inventory)

| Area | Fact | Where |
| --- | --- | --- |
| Plans (live, classic + cmux-next share them) | Free $0; Go $10; Pro $50/mo or $480/yr; Max $200/mo or $1,920/yr; Team $60/seat/mo; Enterprise custom. Lookup keys carry the amount. 93 subscribers grandfathered at $30 Pro. | `web/services/billing/plans.ts:20-73`; cmuxterm-hq `plans/pro-pricing-launch.md:33-40` |
| AI usage policy | PASS-THROUGH: usage above the included amount billed at provider cost, multiplier 1.0 (Lawrence, 2026-10-13). Included per plan are test placeholders: Go 5, Pro 20, Max 100, Team 20 USD. Founders and Apple: hard stop at included. | `plans/cmux-next/usage-billing.md:7-11, 309`; `backend/apps/api/src/billing-catalog.ts:7-61` |
| Chief credits | USD, stored as integer micro-dollars in each team's `UsageMeterDO`; price = provider cost x `CHIEF_CREDITS_MARGIN` (default 1, clamp 1-10); one-time Stripe Checkout top-ups 10/20/50/100 USD, test-mode key only; signed 7-day top-up link; `credits_exhausted` posts one notice per conversation. | `backend/apps/api/src/credits.ts:16-63`, `credits-checkout.ts:24-107`, `chief-brain/credits-gate.ts:8-124` |
| `chief_placed` | A Chief placed on the user's own paired server is never charged by the hosted brain. Claude Code turns on a Freestyle VM via sr2 record `cost_usd: 0`. | `brain-do.ts:331,377`; `chief-brain-cc/turn.ts:198`; test `apps/api/test/chief-brain-place.test.ts` |
| Prod credits | Lawrence's default Chief unplaced; Worker brain (Kimi) charges credits, about $49.99 left (a111, 2026-10-20). | chat a111 |
| Open-model router | Catalog ceilings ("card", USD/1M in/out): glm-5.3-flash 0.25/0.8, deepseek-v4.1-flash 0.4/1.5, kimi-k2.7-code 1/4, glm-5.3 1.5/5, kimi-k3 3.5/16; free tier 300k tokens/device/day. There is no GLM 5.2 in the catalog; it is GLM-5.3. | `backend/apps/api/src/inference/catalog.ts:14-217`, `free-device-do.ts:116-127` |
| Claude rates | Bedrock: Opus 5.5 4/20 (cache read 0.2, 1h write 8); Sonnet 5.5 2/10 (0.1, 4); Haiku 5.5 0.1/0.5. | `model-gateway/bedrock-price.ts:23-30` |
| VMs | Pro/Team: 5 concurrent, pool 20 vCPU / 40 GB, max 8 vCPU / 16 GB; Max: pool 80/160, max 32/64; Go: 1 VM, 40 VM-hours. Flat, no VM-hour overage; plan budgets off (`CMUX_VM_PLAN_BUDGETS`). | `web/services/vms/entitlements.ts:209-219`, `goUsage.ts:8-11`, `planUsage.ts:53-66` |
| Freestyle tenant VMs (a205) | One tenant = one Stack team; VM create credits (Stack items) and Cloud credits (USD) are two ledgers today; 402 now carries an upgrade link. | cmuxterm-hq `plans/freestyle-tenant-DESIGN.md` (#2610, eef94375164d) |
| Hub VM | 4 vCPU / 8 GiB always on = $193/month, which matches Freestyle list price exactly (section 3). | a161, cmuxterm-hq `5d08849650bc` |

a205 confirmed (2026-10-20): one credits unit, Cloud credits in USD in the team's existing
`UsageMeterDO` ledger with its top-up link. Lines that convert to credits: workflow steps,
sandbox seconds by size (its estimate $0.13/h for 2 vCPU / 4 GiB and $0.26/h for 4 vCPU / 8 GiB
is our Freestyle cost; the list price below adds 12%), and model tokens. Classic Cloud VM create
credits are not extended to cmux-next. Workflow steps are priced at Cloudflare cost
($0.80 per 100,000 steps, `automations-billing.md` section 3), which is too small to show on the
page; they appear as a line in Settings › Billing.

This design does not add a billing backend. It sets the numbers and the story; the ledger is
the existing Chief credits ledger, and a205 owns merging VM time into it.

## 2. Model

1. **Chief is the product.** Plans are named by how much Chief you get, not by seats of an app.
2. **One unit: Chief credits = US dollars.** Model tokens and sandbox time draw from one balance
   (already true in the ledger; a205 folds VM create credits in).
3. **Included baseline per plan, framed in open-model tokens.** Included credits pay for any
   model, but the card says what they buy on Kimi K2.7 Code, because open models go 4.2x further
   than Opus (section 3). Chief defaults to open models.
4. **Tokens at cost above included** (keeps the 2026-10-13 pass-through decision). Bring your own
   Claude Code / Codex subscription on your Mac: free on every plan (`chief_placed`).
5. **Sandboxes by the hour** at about 1.12x Freestyle, paused when idle (storage only).
6. **Plans differ by capability, not by cheaper tokens:** Free is a hard stop with open models
   only; paid plans add frontier models, overage, more parallel sandboxes and bigger sizes.

Why included credits are not open-model-only: because credits are priced at cost, one included
dollar costs us one dollar whatever it buys, so an open-only rule protects no margin and only
confuses. Open models still win because the same dollar buys about 4x the work.

## 3. Unit economics

### Tokens

A Chief turn is mostly cached context. Mix used everywhere (`CHIEF_TOKEN_MIX`): 10% fresh input
(Claude writes the 1h cache for it), 85% cached input, 5% output. Open models without a published
cached rate are assumed at 20% of input (conservative; DeepSeek's real cache hit is $0.006).

| Model | In / cached / out (USD per 1M) | Chief blend per 1M | Source |
| --- | --- | --- | --- |
| GLM-5.3 Flash | 0.25 / 0.05* / 0.8 | $0.11 | router catalog |
| DeepSeek V4.1 Flash | 0.4 / 0.08* / 1.5 | $0.18 | router catalog |
| Kimi K2.7 Code | 1.0 / 0.2* / 4.0 | **$0.47** | router catalog; first-party $0.95/$4 (platform.kimi.ai, 2026-10-19) |
| GLM-5.3 | 1.5 / 0.3 / 5.0 | $0.66 | router catalog; Z.ai $1.4/$4.4, cached $0.26 (docs.z.ai, 2026-10-19) |
| GPT-5.6 Terra | 2.0 / 0.2* / 12 | $0.97 | developers.openai.com/api/docs/pricing (2026-10-19) |
| Claude Sonnet 5.5 | 2 (write 4) / 0.1 / 10 | $0.99 | Bedrock table; claude.com/pricing (2026-10-19) |
| Claude Opus 5.5 | 4 (write 8) / 0.2 / 20 | **$1.97** | Bedrock table |

\* assumed. The catalog card is a ceiling; the router buys from the cheapest provider, so open
models usually cost us less than the card we charge. That gap is our only token margin.

What a month of Chief costs (22 workdays unless noted):

| Profile | Turns/day x tokens | Tokens/month | Kimi K2.7 | Opus 5.5 |
| --- | --- | --- | --- | --- |
| Light | 10 x 60k | 13.2M | $6.20 | $26.00 |
| Typical (calculator default) | 40 x 60k | 52.8M | $24.82 | $104.02 |
| Heavy (this Chief, 30 days) | 200 x 100k | 600M | $282 | $1,182 |

### Sandboxes

| Provider | 2 vCPU / 4 GB per hour | Source (accessed 2026-10-19) |
| --- | --- | --- |
| Freestyle (our cost) | $0.132 ($0.04032/vCPU-h + $0.0129/GiB-h; storage $0.000086/GiB-h) | freestyle.sh/pricing |
| **cmux-next list (proposed)** | **$0.148** ($0.045/vCPU-h + $0.0145/GB-h; paused $0.08/GB-month) | this doc |
| E2B | $0.166 ($0.000014/vCPU-s + $0.0000045/GiB-s) | e2b.dev/pricing |
| Daytona | $0.166 ($0.0504/vCPU-h + $0.0162/GiB-h) | daytona.io/pricing |
| Modal | $0.238 | modal.com/pricing |

Sandbox margin is 12% on list, which pays for snapshots, egress and idle minutes before the
pause. We stay about 11% under E2B and Daytona.

Always-on machines are the cost trap: a 2/4 sandbox running 24x7 is $96/month at our cost;
4/8 is $193 (the hub bill). So the Chief brain stays serverless (token cost only) and sandboxes
start on demand and pause when idle. An always-on Cloud Chief VM, if sold, is an add-on at list
($108/month for 2/4), not part of any plan.

### Plans: margin when every included credit is spent

Stripe fee assumed 2.9% + $0.30 per charge. Included dollars cost one dollar (pass-through).

| Plan | Price | Included | Worst-case gross margin (monthly / yearly) | At 50% use of included |
| --- | --- | --- | --- | --- |
| Free | $0 | $3, hard stop | cost up to $3 per active free user | about $1.50 |
| Pro | $50 / $40 yearly | $25 | 46.5% / 34.5% | 71.5% |
| Max | $200 / $160 yearly | $100 | 47.0% / 34.6% | 72.0% |
| Team | $60/seat | $25/seat pooled | 54.9% | 76% |
| Enterprise | custom | committed | set per deal | |

A test enforces a 30% floor on every paid plan and billing interval
(`worstCaseGrossMargin`). The yearly prices are why Pro stops at $25 and Max at $100 included:
$30 on Pro yearly would fall to 22%.

Margin risk outside this table: today's flat Cloud VM entitlements. A Pro user who keeps the
20 vCPU / 40 GB pool running 24x7 costs about $965/month at Freestyle list. In cmux-next
this risk is gone: sandbox time draws from Chief credits and classic create credits are not
extended (a205). For classic, `CMUX_VM_PLAN_BUDGETS=on` would cap it.

## 4. Proposed price table (for approval)

| | Free | Pro | Max | Team | Enterprise |
| --- | --- | --- | --- | --- | --- |
| Price | $0 | $50/mo, $40/mo yearly | $200/mo, $160/mo yearly | $60/seat/mo | Custom |
| Included Chief credits / month | $3 (hard stop) | $25 | $100 | $25/seat, pooled | Committed |
| ≈ Kimi tokens / sandbox hours | 6M / 20 h | 53M / 168 h | 213M / 675 h | 53M / 168 h per seat | |
| Above included | stops | tokens at cost, sandboxes at list | same | same, member and team limits | volume rates |
| Frontier models from credits | no (BYO only) | yes | yes | yes | yes |
| Own Claude Code / Codex on your Mac | free, unlimited | free | free | free | free |
| Sandboxes at once / largest | 1 / 2 vCPU 4 GB | 5 / 8 vCPU 16 GB | 20 / 32 vCPU 64 GB | 5 per seat / 8 vCPU 16 GB | custom |

Prices are today's Stripe prices; only the included amounts are new (they replace the test
placeholders Pro 20 / Max 100 / Team 20). Go ($10) is not on the cmux-next page: its 40 VM-hours
plus $5 included can cost more than it earns (usage-billing.md:115). It stays for classic.

## 5. Competitors (published prices, accessed 2026-10-19)

| Product | Plan | Price | Included | Source |
| --- | --- | --- | --- | --- |
| Cursor | Plus / Premium / Super / Ultra / Teams | $8 / $30 / $100 / $200; Teams $30-200/seat | weekly pools (Premium 4x Plus); third-party models at API list; Teams +$0.25/M "Cursor Token Rate" | cursor.com/pricing, cursor.com/docs/account/pricing |
| Claude | Pro / Max 5x / Max 20x / Team | $20 / $100 / $200 / $25 seat | rate limits; Max includes API credits equal to its price | claude.com/pricing, support.claude.com 11049741 |
| Devin | Pro / Max / Teams | $20 / $200 / $40 seat ($80 min) | daily and weekly quota; per-ACU price not published (devin.ai/pricing 404) | docs.devin.ai/admin/billing/self-serve |
| Replit | Core / Pro | $20 / $100 | credits equal to price; effort-based charges | replit.com/pricing |
| Warp | Build / Max / Business | $20 / $200 / $50 seat | usage equal to price at API rates; BYO keys | warp.dev/pricing |
| Conductor | Pro / Teams | $50 / $60 seat | own subscriptions; 8-core cloud workspaces free for now | conductor.build/pricing |
| ChatGPT / Codex | Plus / Pro | $20 / $100-500 | shared allowance, credits | learn.chatgpt.com/docs/pricing |
| E2B | Pro | $150/mo + usage | sandboxes only | e2b.dev/pricing |
| Daytona | PAYG | usage, $200 free | sandboxes only | daytona.io/pricing |
| Freestyle | Hobby / Pro | $50 / $500 (counts toward usage) | VMs only | freestyle.sh/pricing |

Read: Warp, Replit and Claude Max give included usage roughly equal to price. We give half on Pro
and Max because our tokens are at cost with no markup and we add sandboxes, which nobody else
bundles with model usage. The honest pitch: "Chief, at cost, plus machines". Cursor marks up
(+$0.25/M on Teams, +20% Max Mode historically); we do not.

## 6. Variants (gallery)

Opened as a tab in the Home right pane: `plans/cmux-next/pricing-gallery/index.html`.

- **A · Chief-first plans + calculator (Recommended, built).** Keeps current prices, Chief headline,
  included credits in Kimi tokens and sandbox hours, calculator under the cards.
- B · Calculator-first: sliders and one big number; plans are the answer.
- C · Credits store: packs with bonus credits; breaks "at cost".
- D · One plan + usage ($20 + metered): simplest, but reprices today's Pro.
- **E · Settings › Billing & credits (in app, Recommended):** balance, split by open/frontier/
  sandboxes, included bar, default model, BYO toggle, spend limit, idle pause, top-ups 10/20/50/100.
- **F · Out-of-credits card in the Chief chat (Recommended):** on `credits_exhausted`, one card with
  Add credits (↩, opens the signed `topupLink`), Use open models (⌘1), Use my Claude Code (⌘2);
  Free sees Upgrade to Pro.
- G · Sandbox cost hint: floating card when Chief starts a sandbox; Approve/Deny only above the
  spend limit.

E-G are designs only. The Swift work (Settings pane, chat card) is a follow-up once the numbers
are approved; it reads `GET /v1/credits` and the existing top-up link, no new backend.

## 7. Calculator

`estimateChiefBill(plan, usage)`: tokens = turns/day x tokens/turn x workdays (x seats on Team);
token cost = tokens x Chief blend of the model; sandbox cost = hours x list rate; included applies
to all usage up to the plan amount; Free stops at included; `fits` is false when the plan cannot
run the usage (hard stop, frontier on Free, too many parallel sandboxes, size too big).
`recommendChiefPlan` picks the cheapest plan that fits (Team when seats > 1, else Enterprise).
Default month (40 turns, 60k tokens, Kimi, 2 sandbox h/day): $31.33 usage; Pro $56.33.

## 8. Rollout (after approval)

1. Approve numbers (section 9). Update `CHIEF_PLANS` if changed; tests pin them.
2. a205/backend: included amounts into `billing-catalog.ts` price set v2 (test mode), VM time into
   the Chief credits ledger, `CMUX_VM_PLAN_BUDGETS=on`.
3. Stripe test mode: graduated metered prices per plan via `web/scripts/stripe/provision-catalog.sh`.
   Live objects only after a test-clock invoice matches the calculator.
4. Swift: Settings › Billing (E) and the chat card (F).
5. Swap `/pricing` to the Chief layout (or move `/next/pricing` there) and drop the preview gate.

## 9. Decisions for the user

1. Included Chief credits per month: Free $3 (hard stop), Pro $25, Max $100, Team $25 per seat.
2. Plan prices stay as today: Pro $50 ($40 yearly), Max $200 ($160 yearly), Team $60/seat.
3. Tokens above included at provider cost (multiplier 1.0, as decided 2026-10-13), or a margin
   (for example 1.1x on frontier only).
4. Sandbox list price $0.045/vCPU-h + $0.0145/GB-h (≈ $0.148/h for 2 vCPU / 4 GB), paused
   $0.08/GB-month.
5. Free has no hosted frontier models (BYO only).
6. Bought credits expire after 12 months (the page says so; the ledger has an `expired` kind but
   no rule yet).
7. Go is left off the cmux-next page.

## 10. Open questions

- Team included per team or per seat (usage-billing.md asks the same): this proposal is per seat, pooled.
- Annual plans and usage: today annual plans are never billable for usage and stop at included
  (usage-billing.md:352). Keep, or add a usage item to annual subscriptions?
- Chief turn token mix is assumed (10/85/5). Measure it from `credit_entry` charge rows before launch.
- Cursor's old Pro/Pro+ and Devin ACU rates are not on official pages any more; left out.
