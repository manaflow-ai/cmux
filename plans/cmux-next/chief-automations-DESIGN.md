# cmux next: Chief jobs (automations from chat) and the upsell

Status: built 2026-10-25 (a675). Ask (Lawrence, Oct 26 list): "Automations" and "an upsell flow that
sends Stripe links": a person asks Chief for a recurring or triggered job, Chief creates it, it runs in
the cloud with the laptop asleep, and the result comes back to the chat. When a request needs a paid plan
or credits, Chief says so in one line and sends a Stripe Checkout link. Stripe TEST mode only.

Builds on automations-plan.md (SchedulerDO, AutomationRunWorkflow, run history, limits),
org-workflows-DESIGN.md (machine and agent steps), the Cloud Chief (chief-brain-cc/, its `chief-wake`
timer) and credits-checkout.ts (the top-up link). It does not replace them.

## 1. Flow

1. The person writes "every weekday at 9, summarize last night's merged PRs" to their Cloud Chief.
2. The Chief runs `chief-auto add --tz America/Los_Angeles "Morning digest" "0 9 * * 1-5" "PROMPT"` in its
   turn machine. The Worker (chief-brain-cc/jobs.ts `autoCall`) creates an automation in the owner's
   personal team: triggers cron (or `webhook`, or `manual` only) plus manual, body
   `{type: "chief", chief, conversation, prompt}` bound to this Chief and this conversation.
3. At each fire, SchedulerDO starts a run; `AutomationRunWorkflow` makes one durable step `cmux:chief`
   that calls `ChiefBrainDO.chiefJob` on `<chief>/<conversation>`. The brain queues
   "[job auto_…] PROMPT" (plus the trigger input for webhook and event runs) as the Chief's own note
   (`job:<run>`, so a replayed step queues it once) and starts a turn, as `chief-wake` does.
4. The Chief does the job in that turn (its own Freestyle turn machine, tools, GitHub login) and posts
   the result in the chat. No computer of the person is involved.
5. The run ends `succeeded` with outcome "handed to the Chief" once the note is queued; the run history
   (`automation.runs.list`) shows each fire.

`chief-auto ls | run ID | rm ID` list, run now and delete; the Chief reaches only jobs whose body names
itself and this conversation.

## 2. Rules

- Delivery runs only for the Chief's owner: the run's `charged_user` (whoever last created or changed
  the automation) must equal the brain's owner, else the run fails `chief.forbidden`. A Chief that never
  answered in that conversation fails `chief.not_found`; a placed Chief (a paired computer runs it) fails
  `chief.chief_placed`, because a job must run with the person's computers off.
- An automation cannot start a `chief` automation (like `agent_prompt`: more power than its classes).
- A `chief` run's deadline is RUN_GRACE_MS (1 h): it only hands the prompt over.
- The note is the Chief's own (kind `chief`, effect authorized, as the timer): the person asked for the job
  when it was made. The note says it is not the person's word now.
- Out of credits: delivery still queues the note; the turn refuses and posts the existing one-per-hour
  top-up notice with its signed Stripe Checkout link (credits-checkout.ts).

## 3. Upsell

- Gate (default picked by a675): on the free plan a Chief has 1 job (FREE_CHIEF_JOBS). The plan is the one
  the model router and Cloud machines read (TeamDO.inferencePlan with the owner's Stack user). A plan
  read that fails lets the job through (an outage never blocks a paying person).
- The next `chief-auto add` answers 402 `automation.plan.required` with `plan: pro` and `checkout`: a
  signed link (`/v1/billing/plan/<payload>.<hmac>`, BILLING_LEVELS_KEY, 7 days). Opening it creates a
  Stripe Checkout session (subscription, inline `price_data` from the pricing proposal: Pro $50/month,
  Max $200/month) with the test key only, and redirects there. `creditsKey` refuses a live key, and a
  test key on production. No Stripe Product or Price object is made.
- The Cloud Chief prompt (turn.ts) says: one line, what the plan adds and its price, the link as a
  Markdown link, nothing is charged until they pay, never say you bought anything, once per ask.
- The local Chief keeps the `paid-plans` skill (`cmux billing checkout`, through the Mac app and
  cmux.com).
- After payment (#25574): the link names the Chief and conversation that sent it (signed), the session
  carries them in metadata and returns to `/v1/billing/plan/done?session_id=...`. The return page and
  the signed webhook (`/v1/hooks/stripe/credits`, checkout.session.completed) share `grantPlanSession`:
  a paid test-mode session at the plan's price becomes the team's test plan grant in TeamDO
  (`test_plan_session`, one row per session, marked revoked, never deleted), once per session. `inferencePlan` honors it off production only, so the job gate,
  the model router and Cloud machines see the plan on their next read (no restart).
  customer.subscription.deleted marks it revoked. The Chief's conversation gets one "[billing] ... is on"
  note (`plan:<session>`) that starts a turn: it says the plan is on in one line and redoes the add.
- User-facing copy names no vendor (return pages, the skill's example reply, both prompts; evals check).

## 4. Proof (2026-10-25)

`backend/apps/api/test/chief-jobs.test.ts` (workerd, on the cmux-lawrence Mac mini), red before the
change (3 of 3 failed: no `auto_` action, no `chiefJob` RPC), green after:

- a job the Chief makes runs: create (cron with tz), list, a forged id refused, run now; the Workflow
  completes, a second Chief turn starts with no message from anyone and its prompt has the job note; the
  reply is in the conversation; `chief-auto` ships to every turn machine;
- free plan: the second job answers 402 with a checkout link; the link answers 303 to the Stripe page,
  made with an `sk_test_` key, mode subscription, 5000 cents monthly, team and plan in metadata; a forged
  link is 404;
- delivery refuses another member's charge, no charge, another Chief; the owner's run is queued once.

## 5. Open

- A paid test-mode checkout grants a test plan off production only. The live plan comes from web
  billing (cmuxPlan). A live key, real prices or a live grant from this link need Lawrence's OK.
- The local (Mac) Chief has no `chief-auto`: its jobs need the Cloud Chief, or a paired install token
  calling `automation.create` with a `chief` body for the Cloud Chief's conversation.
- No staging run through the deployed Worker yet (needs a deploy; the Worker change is additive).
- A run does not wait for the Chief's reply; a turn that fails after delivery shows in the Chief's run
  view, not in the automation's run.
- Event triggers (GitHub through ConnectionDO) work with a `chief` body in the reducer, but `chief-auto`
  offers only cron, webhook and manual.
