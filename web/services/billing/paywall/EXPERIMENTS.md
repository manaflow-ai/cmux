# Paywall and pricing experiments

This file pre-registers every experiment that the paywall optimizer runs.
Write the entry before the experiment gets traffic. Do not change the
metrics or the decision rule of a running experiment. To change them, start
a new experiment key (for example `ios-paywall-v2`).

Code:

- `experiments.ts`: the registry. The optimizer, the change log and the staff
  variants route read it.
- `facts.ts` and `validator.ts`: the copy rules. Every payload is validated
  before it is served. An invalid payload serves control, logs an error and
  records a `payload_invalid` change.
- `optimizer.ts` and `runAll.ts`: the optimizer. Run it with
  `scripts/paywall-optimizer/run.ts` (use `--dry-run` to write nothing) or
  with the daily `/api/cron/paywall-optimizer` cron.
- `iosPaywall.ts`: assignment and exposure for the iOS app.

## Rules for every experiment

1. **One platform per experiment.** Each experiment runs on iOS or on the web,
   never on both. Rates from different platforms are never pooled. A
   cross-platform question needs two experiments and two reports.
2. **Sticky bucketing per user.** The unit is the cmux account. Its
   `distinct_id` is the account's user id. The server records the first
   variant and the copy served to each user in `paywall_assignments`. The
   user keeps both when the optimizer changes the traffic split, when the
   copy in the flag is edited, and when the flag is unavailable. The only
   exception is the kill switch: when the flag is off, everyone gets
   control. The analysis counts each person once, in the variant of their
   first exposure.
   - A copy edit therefore reaches only new users. To test new copy, add a
     new variant key. Do not edit an exposed variant: the optimizer logs
     every edit as `copy_changed`, and that arm then holds two versions.
3. **Assignment and exposure are different events.**
   - **Assignment:** the server records `paywall_assigned` when it serves a
     variant (at most once per user, variant and UTC day). It carries
     `paywall_experiment`, `paywall_variant`, `paywall_layout`,
     `paywall_platform`, `paywall_channel`, `paywall_internal` and
     `paywall_sticky`. The app also fetches the config from the Settings
     plan row, so an assignment is not an exposure.
   - **Exposure:** the app's own view event (`ios_paywall_viewed` for iOS),
     which carries `paywall_experiment` and `paywall_variant`. A person is
     exposed at their first view event after their first assignment (5
     minutes of clock skew allowed). The person is counted in the
     server-assigned arm, never the arm the client reports. The report counts
     people whose app reported a different arm; that number must be 0.
   - At current traffic, about 1 view a day, counting config fetches would
     dilute the arms, which is why the client view event is the exposure.
   - **PostHog Experiments:** use the custom exposure event
     `ios_paywall_viewed`. The analytics proxy stamps `$feature/<experiment>`
     from `paywall_variant` on every app event that carries both properties,
     so PostHog can read the arm. It carries `paywall_experiment`,
   `paywall_variant`, `paywall_layout`, `paywall_platform`,
   `paywall_channel`, `paywall_internal` and `paywall_sticky`.
4. **Exclusions.** These groups never enter the analysis:
   - internal accounts (staff, and `PAYWALL_EXPERIMENT_INTERNAL_EMAILS`),
     which are tagged `paywall_internal` on the assignment;
   - synthetic probe accounts, which never enter the experiment;
   - non-production channels (`paywall_channel` other than `production`);
   - for web experiments, also bots (that predicate is set in each web
     experiment's definition).
   Internal accounts still get variants, so that staff can check them.
5. **Sample-ratio-mismatch (SRM) check.** Every run compares the first
   exposures since the last allocation change with that allocation, using a
   chi-square goodness-of-fit test. The window starts 15 minutes after the
   change, because flag evaluations are cached for a few minutes. First
   exposures served from a sticky assignment are not counted.
   - If p < 0.001, or if anyone is first exposed to a variant at 0%, the
     optimizer stops all changes, records `srm_halt` once and reports the
     halt daily.
   - Traffic stays frozen until a person explains the mismatch and runs
     `scripts/paywall-optimizer/clear-srm.ts`. That command records
     `srm_cleared` and restarts the window.
6. **Change log.** Every change is appended to `paywall_experiment_changes`
   with a timestamp, the actor and the reason. Changes are: variant created,
   variant retired, copy changed, invalid payload, allocation changed, SRM
   halt and SRM cleared. Each run is stored in `paywall_experiment_runs` with its snapshot and
   its daily markdown report. Staff can read both through
   `GET /api/billing/paywall/variants?experiment=<key>`.
7. **Who may change traffic.** The cron writes splits only when
   `PAYWALL_OPTIMIZER_APPLY=1` (set in production after merge: full
   automation, visible in the change log). Otherwise it observes: it records
   the run and the proposed split, but it does not write the split to the
   flag. If the flag write fails (for example, the key has no write scope),
   the run logs the error, reports a billing error, and stays in observe
   mode.

## Default decision rule (Beta-Bernoulli Thompson sampling)

- Each variant has a Beta(1 + conversions, 1 + non-conversions) posterior on
  its primary-metric rate. P(best) comes from 20,000 posterior draws, seeded
  by experiment and date, so a run can be reproduced.
- **Minimum sample.** Until every live variant has at least 50 exposed
  people, the split stays equal across the live variants.
- **Allocation after that.** Traffic is proportional to P(best). Control
  keeps at least 10%, and every other live variant keeps at least 1%.
- **Retirement.** A variant other than control is retired (set to 0%) when it
  has at least 300 exposed people and P(best) < 0.02. People who were
  already exposed keep that variant (rule 2).
- Halts (SRM, control not live, flag off) are checked before everything
  else.

## Live arm cap

At most 4 arms get traffic at once: control and 3 challengers
(`maxLiveArms`). Other variants wait at 0% as `queued`. When a challenger
is retired, the optimizer promotes the next queued variant and records
`variant_promoted`.

- The queue is the experiment's reviewed `queue` list (for `ios-paywall-v1`:
  the seeded 0% variants, layouts every app can draw first). A variant that
  was ever promoted or retired, or that an operator set to 0% by hand, is not
  promoted again.
- A queued variant is skipped (and the report says why) while its payload
  fails the validator, while it cannot be served (the trial arm without the
  trial keys), or while fewer than 90% of the last 14 days' assignments came
  from apps that can draw its layout (`paywall_app_layouts` on
  `paywall_assigned`). Otherwise most of its users would see `cards`, and
  the arm would be judged on the wrong screen. The new arm starts with no exposures, so
the split goes back to equal until every live arm has 50 exposures again.

The cap exists because of traffic. Every live arm needs its own 50
exposures before traffic can move, and 300 before it can be retired. At
about 1 paywall view a day, 4 arms need about 200 days to reach the first
traffic move, and 7 arms would need about 350. With more arms, every arm's
estimate stays noise for longer, and the optimizer would hold an equal
split for the whole experiment. Fewer arms reach a decision sooner, and the
queue still lets every idea get tested in turn.

## ios-paywall-v1

- **Flag:** `ios-paywall-v1`, a PostHog multivariate flag that the server
  evaluates. The payload of each variant is its copy. The seed is
  `iosPaywallV1.ts`. Create the flag with
  `scripts/paywall-optimizer/create-flag.ts` after the migration is applied.
- **Platform:** iOS, App Store app `com.cmux.app` (channel `production`) only.
- **Who enters:** a signed-in account on the free plan that can buy in the
  app (account-token `eligible` with products), plus internal accounts from
  any channel. Everyone else gets control and has no exposure.
- **Hypothesis:** paywall copy and layout that state concrete Cloud
  capacity, or the outcome (agents keep working while the Mac sleeps),
  increase paid conversion compared with the current screen.
- **Arms:** `control` (the app's built-in copy, cards), `focus-pro`,
  `comparison` and `outcome-copy` start live at 25% each. Queued in this
  order: `pro-yearly-first`, `checklist-pro`, `plantabs-pro`, `hero-pro`,
  `speclist-specs-first`, then 7 more so that every layout has an outcome
  angle ("Run coding agents in the cloud, reach them from your iPhone") and
  a compute angle ("More cloud compute"): `cards-compute`,
  `comparison-outcome`, `focus-outcome`, `checklist-outcome`,
  `plantabs-outcome`, `hero-compute` and `speclist-outcome`. The Paywall
  Lab lists every variant, including the queued ones.
- **Lead with Pro Monthly** (Lawrence, 2026-10-15): control and every seed
  variant highlight Pro and preselect monthly. The one billing-period
  challenger is `pro-yearly-first` (control's copy with yearly preselected),
  first in the queue, so the data decides on yearly.
- **Billing period:** `defaultBillingPeriod` is the period preselected for
  plans that offer both periods. It is not a global Monthly/Yearly toggle,
  because not every plan has a yearly product.
- **Layouts:** `cards`, `comparison`, `focus`, `checklist`, `planTabs`,
  `hero`, `trialTimeline` and `specList`.
  - When the served layout is `specList`, the server adds `planSpecs` (the
    spec lines per plan from `facts.ts` `PLAN_SPECS`). A payload cannot set
    `planSpecs`.
  - The app declares the layouts it can draw in `x-cmux-paywall-layouts`.
    An app that sends no header gets only `cards`, `comparison` and `focus`.
  - The server sends a layout only if the app can draw it. Otherwise it sends
    the variant's `fallbackLayout` if the app can draw that, and else
    `cards`.
  - `trialTimeline` is served only to a trial-eligible user. Every other user
    gets the variant's `fallbackLayout`, which a `trialTimeline` variant must
    have. `fallbackLayout` stays on the server and is never sent to the app.
  - The arm stays the same when the layout falls back. The assignment record
    carries the layout that was actually served (`paywall_layout`).
- **Entry-point headlines:** a variant may set `entryPointHeadlines`, which
  maps an `entry_point` to a headline. Each one is validated like
  `headline`. The app uses it in place of `headline` for that entry point.
- **Primary metric:** the share of exposed people with a
  `subscription_entitlement_granted` event (`source = apple`,
  `environment = Production`) after their first exposure.
- **Secondary metric:** the share of exposed people with
  `ios_paywall_cta_tapped` after exposure.
- **Guardrails:** `subscription_refunded` and `subscription_revoked` among
  exposed people. A guardrail rate above 2 times control, with at least 5
  events, makes a person review the variant before the next run. The
  optimizer reports guardrails; it does not act on them.
- **Minimum exposures:** 50 per variant before traffic moves, and 300 before
  a variant can be retired.
- **Decision rule:** the default rule above.
- **Stop:** when one variant has P(best) > 0.95 with at least 300 exposures,
  or after 120 days. Then ship the winner as the new control under a new
  experiment key.

### What to expect at current traffic

In the 14 days to 2026-10-14 there were about 82 iOS paywall views, and 71 of
them came from the beta (TestFlight) app. The App Store app had about 11
views. That is roughly 0.8 eligible views a day. Four arms need
4 x 50 = 200 exposed people before the first traffic move, which is about
250 days at that rate. So for months the optimizer will hold the equal 25%
split and report "hold equal split". This is correct behavior, not a bug.
With a base conversion rate in the low single digits, a 50-person arm cannot
tell the variants apart. Moving traffic earlier would follow noise. The
experiment pays off only when App Store paywall traffic grows, or when it is
run with fewer arms.

## web-pricing-v1

- **Flag:** `web-pricing-v1`, a PostHog multivariate flag with no payloads.
  The variants are code in `../pricingExperiment/webPricingV1.ts`, and each
  one passes `copyErrors`. A flag variant that the code does not define, or
  whose copy fails, is served as control. Create the flag with
  `scripts/pricing-experiment/create-flag.ts` after merge.
- **Platform:** web, the English `cmux.com/pricing` page only. Other locales
  always get control and have no exposure. Web results are never pooled with
  iOS results.
- **Assignment:** the proxy evaluates the flag locally with PostHog's hash on
  the visitor's PostHog distinct id. A first visit with no PostHog id hashes a
  random id. The result is pinned in the `cmux_wp1` cookie for one year, so a
  later traffic change does not move a visitor. Each non-control arm is a
  static route (`/pricing/<variant>`) that the proxy rewrites to, so the page
  arrives as server HTML with no flash. The proxy reads the flag definition in
  the background, at most once a minute. Until it has a fresh definition, the
  experiment is off.
- **Difference from rule 2:** the unit is the PostHog person, not the cmux
  account, because most visitors are anonymous. The `cmux_wp1` cookie replaces
  `paywall_assignments`. Sign-in merges the anonymous person into the account
  with `identify`.
- **Assignment and exposure (rule 3):** the proxy chooses the arm and pins it
  in the `cmux_wp1` cookie. When the page renders, the browser records
  `paywall_assigned` with that pinned arm and then the exposure,
  `$feature_flag_called`. Both carry `paywall_experiment`, `paywall_variant`,
  `paywall_platform = web`, `paywall_channel` and `paywall_sticky` (true when
  the browser has an existing pin but no visit in the last day, so the SRM
  window skips it). The browser sends the assignment record because the proxy
  does not know the browser's PostHog id on a first visit. The arm still comes
  from the proxy's cookie, never from the page. Unlike iOS, the web
  assignment is therefore client-reported, with the same trust as any
  browser event. Both events come from one page view, so the optimizer's
  client-variant mismatch count is not an app bug on the web: a non-zero
  count means sign-in merged people from devices that hold different pins
  (cross-arm contamination). Both events are recorded only when the proxy
  put this browser in the running experiment (`cmux_wp1_live` cookie), the
  pinned arm is the rendered one, and the URL is `/pricing`. A bot (the proxy
  gives it no cookie), a visitor without JavaScript, a paused experiment and a
  staff preview of `/pricing/<variant>` never make an assignment or an
  exposure.
- **Exclusions** (on the assignment record): `paywall_channel = production`
  (only `cmux.com`; preview deployments report to the same project),
  `is_internal_user` (registered by the route tracker for verified company
  accounts), `is_synthetic`, and headless user agents.
- **Paid accounts:** everyone is bucketed and keeps their arm, but an exposure
  counts only when the visitor can still convert. The route tracker registers
  `account_plan` (the signed-in account's plan when the event is sent), and
  exposures with a paid plan (`go`, `pro`, `max`, `team`) are left out. A
  person whose only exposures were on a paid plan is therefore outside both
  the exposure count and the primary metric. A free account that later buys
  keeps its earlier free exposure, so its conversion counts. A signed-out
  visitor counts as free; a paying customer who browses signed out is a
  known, small leak. Events buffered before the identity resolves take the
  plan resolved for that page view, not a value persisted from an earlier
  visit.
- **Hypotheses:** `yearly-emphasis`: a note that yearly billing costs less per
  month raises paid conversion. `highlight-pro`: one recommended plan raises
  Pro checkouts. `outcome-headline`: an outcome headline (agents keep working
  while your Mac sleeps) beats the plain title.
- **Arms:** `control` (today's page), `yearly-emphasis`, `highlight-pro` and
  `outcome-headline`, at 25% each. No arm changes a price, a plan, a feature or
  checkout. Only the title, a subheadline, the emphasized card, a note under
  the button and the first billing period can vary.
- **Primary metric:** the share of exposed people with a live-mode
  `cmux_billing_checkout_completed` after their first exposure. Internal and
  synthetic checkouts are excluded (`is_internal`, `is_synthetic` from the
  checkout session).
- **Secondary metric:** `cmux_billing_checkout_started` tagged with this
  experiment. The checkout route reads the assignment from the cookie, never
  from the URL, and stores it on the Stripe session and subscription.
- **Guardrails:** live-mode `cmux_billing_charge_refunded`, and
  `cmux_billing_plan_switch_started` to a cheaper plan (Max to Pro or Go, Pro
  to Go). The same review rule as `ios-paywall-v1` applies: a guardrail rate
  above 2 times control, with at least 5 events, makes a person review the
  variant before the next run.
- **Kill switch:** the Paywall Lab (`/dashboard/ops/paywall-lab`) turns the
  flag off. Every visitor then gets control within a minute, nobody is
  exposed, and the optimizer holds. Resume turns the flag on with the same
  split. Each use is in the change log with the staff member's email.
- **Decision rule and stop:** the default rule above, and the same stop rule
  as `ios-paywall-v1`.

### What to expect at current traffic

In the 14 days to 2026-10-14, about 3,300 people viewed the production pricing
page, and 95% of the views were in English. In the same period there were 27
live checkouts from the pricing page. So each arm gets about 55 exposed people
a day, and the first traffic move can come after one day. At a base rate near
1%, the arms cannot be told apart for weeks: a 50% lift needs several thousand
exposed people per arm. The control floor keeps at least 10% of traffic on
control while the optimizer follows P(best).

## Adding an experiment (for example web-pricing-v1)

1. Append its definition to `PAYWALL_EXPERIMENTS` in `experiments.ts`. Give
   it a flag key, a platform, a control variant, the exposure predicate
   (`assignmentWhere` with `COMMON_EXPOSURE_EXCLUSIONS`, and an `exposureEvent` and `exposureWhere` with bot filtering for the web), the metrics
   and `validatePayload`. Use `copyErrors` from `validator.ts` for every
   string field.
2. Add a seed flag to `SEED_FLAGS` in `runAll.ts`, so that dry runs work
   before the flag exists.
3. Record the assignment with `paywall_assigned` and the properties in
   rule 3, and send the exposure event from the client with
   `paywall_experiment` and `paywall_variant`. Keep the assignment sticky through `PaywallAssignmentStore`.
4. Add a section to this file before the experiment gets traffic.
