# cmux paid plan: cloud + inference (plan)

Status: BUILDING, 2026-10-23. Stripe TEST MODE only. Owner: the "Paid plan: cloud + inference" agent.

User asks (Lawrence, 2026-10-23):
- "we need to work on paid plan at all, which will include some cloud and some inference, we will
  route to deepinfra and openrouter and vercel router".
- "show all possible harnesses by default, and let user choose model, and if they don't have api key
  set up for it, we will show error message, giving user button to add their own api key, as well as
  add credits for cmux inference, so we need to build out stripe and have payments be super fast".

This note does not start over. Most of the money plumbing exists and is tested in Stripe test mode.
It names what exists, the defaults this plan picks, and the steps still to build.

## 0. What exists (audit, origin/feat-cmux-next at 46e3205f425)

| Piece | Where | State |
| --- | --- | --- |
| Pricing proposal (Free 0, Pro 50, Max 200, Team 60/seat; included credits 3/25/100/25; sandbox $0.148/h list) | `pricing-DESIGN.md` §4, `web/services/billing/chiefPricing.ts`, `/next/pricing` (preview flag) | proposal, not for sale |
| Subscriptions, checkout, webhook, portal | web (Vercel, `main`): `web/app/api/billing/*`, `web/app/api/stripe/webhook`, `web/services/billing/*` | live code for classic plans |
| Plan entitlement | Stack `client_read_only_metadata.cmuxPlan` -> `TeamDO.inferencePlan` (`backend/apps/api/src/inference/plan.ts`) | built |
| Cloud VM entitlement | `domains/cloud-plan.ts`, `cloud-entitlements.ts`, `CLOUD_PLAN_ENTITLEMENTS=on` dev+staging | built, prod off |
| Model router (OpenAI + Anthropic Messages shapes) | `backend/apps/api/src/inference/{route,upstream,providers,catalog,messages}.ts` | built; providers openrouter, vercel, deepinfra, fireworks, baseten, workers-ai |
| Provider brake (USD per provider per UTC day, health cool-down) | `inference/spend-guard-do.ts` | built |
| Usage ledger (one fact per call, member + team counters, 400-day facts) | `usage-meter-do.ts`, `usage-user.ts` | built (cx-y79zh S1-S5) |
| Postpaid overage (level sync to a metered Stripe price, included amount, stop for unbillable) | `billing-usage-sync.ts`, `billing-catalog.ts`, `inference/included-stop.ts` | built, test mode |
| Prepaid cmux credits (ledger, holds, top-up Checkout 10/20/50/100, signed webhook, return-page grant, operator grants) | `credits*.ts`, `usage-credits.ts` | built for Cloud Chief, test key only |
| App billing helpers (Checkout opener, Stripe Link cookie check, live refusal) | `Packages/macOS/CmuxNext/Sources/CmuxNextAccounts/Billing/*`, `AppControl+Billing.swift` | built |
| Keychain API keys | `CmuxNextCodeRouter/Keychain/ProviderKeyStore.swift` | built |
| Harness picker: every acpmux harness for Home Chief | `HomeChiefSettingsView+Engine.swift` (22ec30e4076) | built |

Gaps this plan fills:
1. The router refused every caller without a paid plan, even one holding prepaid credits.
2. Provider order was fixed per model; the cheapest healthy provider was not tried first.
3. No way to pin one provider on staging, so a per-provider staging check was not possible.
4. The new agent chat picker hides harnesses that are not set up, and there is no "missing key"
   card with Add API key / Use cmux credits / Add credits.
5. The credits top-up was built for Cloud Chief only; the app has no fast path to it.
6. VM time is not metered into credits (`cloud.vm_seconds`, a205's lane; see §6).

## 1. Plans (defaults; Lawrence sets the final numbers)

Default picked: keep the `pricing-DESIGN.md` §4 numbers. One unit everywhere: **cmux credits in USD**.

| | Free | Pro | Max | Team |
| --- | --- | --- | --- | --- |
| Price | $0 | $50/mo | $200/mo | $60/seat/mo |
| Included credits / month (inference + cloud) | $3, hard stop | $25 | $100 | $25/seat, pooled |
| Above included | buy credits | at provider cost (postpaid), or prepaid credits | same | same |
| Cloud VMs at once / largest | 1 / 2 vCPU 4 GB | 5 / 8 vCPU 16 GB | 20 / 32 vCPU 64 GB | 5 / 8 vCPU 16 GB |
| Own API key or own Claude/Codex sign-in | free, unmetered | same | same | same |

Prepaid credits are open to everyone, with or without a plan (this change). A prepaid charge is never
a billable fact, so a call is never paid twice.

## 2. Inference router (exists; this plan's changes)

- Endpoint: `POST <cloud api>/v1/inference/chat/completions` (OpenAI) and `/v1/inference/v1/messages`
  (Anthropic Messages, so Claude Code style clients set base URL `<cloud api>/v1/inference`).
  `GET /v1/inference/models` is the public model catalog with prices.
- Providers: DeepInfra, OpenRouter and Vercel AI Gateway (all OpenAI-compatible) are the three the
  user named; Fireworks, Baseten and Workers AI stay as fallbacks where keyed. Keys are Worker secrets
  only (`INFERENCE_DEEPINFRA_KEY`, `INFERENCE_OPENROUTER_KEY`, `INFERENCE_VERCEL_GATEWAY_KEY`); a
  provider without a key is skipped. Provider bodies never reach the client.
- Catalog: `inference/catalog.ts`, open models only (Lawrence 2026-10-10). Each model has a `card`
  (our ceiling price per million tokens) and routes per provider.
- **Cost-based routing (new, step 2):** each route carries the provider's list price (read 2026-10-23
  from each provider's model list with our keys). Live routes are ordered cheapest first by a blended
  price (3 input : 1 output tokens, the agent-turn shape); health still moves a cooled provider last.
- Fallback: before the first byte, a connect error, header timeout, 401/402/403/404/408/409/429 or
  5xx tries the next provider; after the first byte the stream is the answer (exists).
- Metering: cost from the provider's own `usage.cost` (OpenRouter) or `estimated_cost` (DeepInfra),
  else the card; a broken call is charged at its reservation (exists).
- Who pays (resolveCaller): free device tier -> paid plan (included, then postpaid overage) ->
  **prepaid credits (new, step 1)** -> 402 with `details.actions = ["add_credits","add_api_key","see_plans"]`
  and `details.credits.topup_path = "/v1/credits/topup"`. Codes: `inference.plan_required` (no plan,
  no credits), `credits.insufficient` (credits below this call's maximum price).
- **Provider pin (new, step 2, non-production only):** header `x-cmux-provider: deepinfra|openrouter|vercel`
  narrows the routes to that provider, for staging checks per provider. Production ignores it.

## 3. Entitlements

One read per call, in this order, all in the Worker: plan (TeamDO, cached), team cap and member limit
(UsageMeterDO), included-amount stop, credits balance (UsageMeterDO credit ledger), global provider
brake (SpendGuardDO). A Stack outage keeps the last plan copy for 2 h, then 503 retryable, never "unpaid".

## 4. App (step 3)

- Harness picker (new Chief, new agent chat): every acpmux harness by default; not installed / not
  signed in is marked, not hidden. Pick harness, then model.
- Missing-access card (composer notice slot, error tier), at pick time or on the first failed turn:
  - **Add API key**: sheet, stored in the Mac Keychain (`ProviderKeyStore`); cloud Chiefs store it as a
    server-side secret. Never logged or echoed.
  - **Use cmux credits**: the chat's harness points at the cmux router (base URL + the person's cmux
    sign-in token) for harnesses that take a custom base URL.
  - **Add credits** when the router answers 402.
- Usage view: balance, this month's spend per chief/harness, included amount left; upgrade card on a
  402 `see_plans`.

## 5. Payments fast (step 4)

- Default picked: one-time Checkout (`mode=payment`) for credit packs 10/20/50/100 USD, one Stripe
  customer per team (exists), Stripe Link and Apple Pay enabled by Checkout's automatic payment
  methods, so a saved card is one tap.
- Opens in the cmux browser when Stripe Link cookies exist, else an in-app sheet / default browser.
- The balance lands on whichever is first: the signed webhook, or the return page reading the session
  back (both grant once, keyed `topup:<session>`). The app polls `GET /v1/credits` after the return and
  retries the blocked turn on its own. Target: click to usable under 10 s with a saved card; the
  measured number goes in §8.
- Subscriptions keep the web path (`/api/billing/checkout`, portal) unchanged.

## 6. Cloud metering

VM seconds by size at list price ($0.045/vCPU-h + $0.0145/GB-h) as `cloud.vm_seconds` facts, drawn from
included credits then prepaid credits. a205 owns the VM ledger merge; this plan only names the meter.

## 7. Steps (each with a failing test first)

1. Router takes prepaid credits; the 402 names its actions. (backend, done in this change)
2. Cost-based route order + non-production provider pin. (backend)
3. App picker, missing-access card, Add API key, Use cmux credits. (app)
4. Add credits fast path and auto-retry; measure click to usable. (app + backend)
5. Staging: real turns through DeepInfra, OpenRouter and Vercel with the pin. (§8)

## 8. Results (2026-10-23)

Landed on feat-cmux-next: steps 1, 2 and the one-tap Checkout part of 4 (backend), with red then green commits.

Staging (https://cloud-api-staging.cmux.dev, commit a689aab, staging e2e account, `openai/gpt-oss-120b`,
pinned with `x-cmux-provider`), each provider JSON and SSE:

| Provider | JSON | ms | tokens in/out | provider cost USD | SSE | ms | usage chunk |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DeepInfra | 200 "ok" | 3180 | 61/45 | 0.000009907 | 200, 35 chunks | 1061 | yes |
| OpenRouter | 200 "ok" | 937 | 74/51 | 0.000011757 | 200, 16 chunks | 1842 | yes |
| Vercel AI Gateway | 200 "ok" | 1289 | 85/53 | 0.000035 | 200, 32 chunks | 958 | yes |
| auto (cheapest first) | 200 "ok" | 911 | 61/42 | 0.000009397 | 200, 38 chunks | 1195 | yes |

Development (https://cmux-api-development.debussy.workers.dev, Stripe test mode, same account, no plan):
- No plan, no credits: 402 `inference.plan_required`, `details.actions = [add_credits, add_api_key, see_plans]`.
- `POST /v1/credits/topup {usd: 10}`: Checkout URL in 380-500 ms.
- First top-up (new card 4242): click Pay to usable (balance $10 seen, then a turn answered 200 on
  credits) **6.4 s**.
- Second top-up: Checkout opens with the email and the saved card (•••• 4242) filled in, so Pay is one
  tap; click to the return page that grants the credits **3.4 s**; balance 19.99 USD after.
- Staging has no Stripe key by design: it shares the development Stripe sandbox (usage-billing.md §9).

## 9. Needs Lawrence (not done by agents)

- Final prices and included amounts (today: the §1 proposal; `billing-catalog.ts` still has 5/20/100/20).
- Live Stripe keys and turning on real charges (code refuses live keys; `BillingLivePolicy.shipped`).
- Credit margin (`CHIEF_CREDITS_MARGIN`, default 1.0 = at cost).
- Signing provider accounts or adding payment methods; any spend over $20.
