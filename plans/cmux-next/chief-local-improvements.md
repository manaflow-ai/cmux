# Local Chief: the changes that help most, measured

Lawrence (Nov 18-19): "we need to significantly improve chief", "how can we drastically improve
local chief as well?". This plan ranks the local Chief host's problems by what they cost the
person, from one week of the real Chief's traces (Nov 12-18), and says how each change is
measured. The recursive/Cloud Chief is a1230's lane and is not in this plan.

Measures (read-only, seconds, no model):

- `Native/OptChat/optchat-chief/measure/chief_loop_stats.py --since D --until D`: turns per
  trigger, cost, silent share, reports, report -> first post, posts per subagent per day,
  refused posts, nudges.
- `chief_health` (the host's own `optchat-chief health`): reply latency, first token, turns cut
  by a restart.
- The replay in section "Replay" below: which turns a rule would remove.

## Baseline, Nov 12-18 (7 days)

| Measure | Value |
| --- | --- |
| Person messages | 116 (145 person turns) |
| Chief turns | 2,072, $2,303 at list price, $1.11 a turn |
| Turns by trigger | report 1,250 (60%, 73% post nothing), untold 595 (29%), person 145 (7%), wake 58, watch 15 |
| Subagent reports | 1,787 from 124 subagents; 37% say they are not done; p50 8, p90 38 a subagent |
| Reports followed by the subagent's own background notice (it ended its run only to wait) | 860 of 1,787 |
| Turns with only such waiting reports, or `[untold]` about them, to wake them | 1,066 (51%, $1,124) |
| Report -> first post that names it | p50 150 s, p90 1,100 s |
| Posts naming one subagent on one day | p50 4, max 44; 130 of 208 (subagent, day) pairs told 3+ times |
| Posts refused as too long | 108 |
| Reply to a person, posted -> first draft | p50 20.6 s, p90 73 s; first token p50 5.6 s |
| Turns that end with the Chief's own stop or sleep | 1,499 of 1,519 (Nov 15-18) |
| Turn sessions kept for the next turn | 0 (`layout.kept` always null) |
| First request of a turn | reads 26.7k tokens, writes 66.8k tokens (p50), every turn |

## Ranked changes

1. **A subagent that ends a run only to wait on its own background work wakes no Chief turn.**
   *Evidence:* 860 of 1,787 reports were "red is still running, I report when it ends", followed
   by the subagent's own notice. Each one started a Chief turn, and the outcome ledger then forced
   an `[untold]` turn about a status: 51% of all turns. The person got the same status 3+ times a
   day for 130 of 208 subagent-days. *Fix:* `finish_sub` tracks the run's pending background work
   (acpmux `process_update`, daemon `bg_start` tasks until their notice). A run that ends with work
   pending and a report that says it waits (`sub_watch::waits`: never one that landed, asks,
   is blocked or waits on a person) goes to the Chief quietly. The run the notice starts reports
   as before. A safety tick (10 min) surfaces a held subagent whose work ended with no wake, or one
   that waits past 3 h, once. *Measure:* report-triggered and untold turns per day, posts per
   subagent per day. Replay: -739 turns (-36%, -$762 a week). **Built** (tests/subagent_waiting.rs).
2. **A turn the Chief ends with its own stop or sleep keeps its session.** *Evidence:* the keep
   rule kept only a clean end, but 98.7% of turns end with the Chief's stop/sleep (a cancel), so no
   session was ever kept and every turn wrote its 67k-token prefix to the cache again. *Fix:*
   `end_turn_by_tool` marks the interrupt as the Chief's own; such an end keeps the session (the
   owner's stop still ends it). *Measure:* `layout.kept` share, first-request `cache_write` p50,
   $/turn. Estimate: a kept turn reads its prefix and writes only the delta (~5k tokens) instead of
   ~67k. **Built** (tests/kept_turn_session.rs).
3. **One open-items ledger instead of prose "owed" lists.** *Evidence:* sleep notes and `[untold]`
   prompts carry prose lists of what is owed; the Chief re-reads and re-tells them (posts per
   subagent per day above). *Fix:* the outcome ledger holds one row per subagent outcome (owed,
   told, superseded) and the turn prompt shows only rows not yet told. *Measure:* posts naming one
   subagent per day; untold turns.
4. **No refused posts.** *Evidence:* 108 posts in a week were refused as too long and written
   again (one more model call each, 15-40 s more for the person). *Fix:* the send tool trims a
   long post to its first lines and attaches the rest as a file, or the prompt states the limit
   with the count left. *Measure:* `chief.reply_too_long` per week -> 0.
5. **Drop the duplicate 33 KB folder context.** *Evidence:* each turn carries a
   `<cmux-folder-context>` block that repeats the session AGENTS.md, which is already the system
   prompt (33,483 bytes). *Fix:* the Chief session folder holds no AGENTS.md copy, or the harness
   skips folder context for the Chief preset. *Measure:* first-request tokens (read + write).
6. **Faster first reply to the person.** *Evidence:* posted -> first draft p50 20.6 s, p90 73 s,
   with first token at 5.6 s: the rest is tool calls before the reply. *Fix:* a person turn answers
   first (a short reply), then works; kept sessions (2) also cut the prefix write. *Measure:*
   `posted_to_first_draft_ms` p50/p90.
7. **Report -> told latency.** *Evidence:* p50 150 s, p90 1,100 s from a final report to the
   first post that names it, because report turns queue behind waiting-report turns. *Fix:* (1)
   removes most of the queue; a landed report sorts first in the turn's messages. *Measure:* report
   -> first post p50/p90.
8. **Keep cap tuned to real turns.** *Evidence:* with (2) on, a kept session grows by each turn's
   tool results; `KEEP_MAX_TOKENS` (120k) decides when it starts fresh. *Fix:* set the cap from the
   measured cost curve (read cost of a longer prefix vs one full write). *Measure:* $/turn by
   kept-session size.
9. **Lose no turn to a restart.** *Evidence:* 10 turns a week were cut by a host restart, and 6
   subagents were marked stuck. Small, but each one is a person's message with no answer until
   the next wake. *Fix:* a turn cut by a restart is run again from its saved messages on start.
   *Measure:* turns cut by a restart with no later turn for the same messages -> 0.

## Replay (change 1)

From `traces/2026-11-1[2-8].jsonl`: a report is "waiting" when the subagent's next event is its
own background notice (its work was pending) and `waits()` holds on the report text. Then a turn
is removed when every message that woke it is such a report, or an `[untold]` about one.

| Turns | Before | After (replay) |
| --- | --- | --- |
| All | 2,072 | 1,333 (-36%) |
| Cost at list price | $2,303 | ~$1,541 (-$762) |
| Waiting reports held | 0 | 608 of 860 |

The rest (252 waiting reports) have words the rule leaves loud on purpose (a question, "blocked",
a person named), or no pending work the host can see.

## State

| Item | State | Landed | Measure now | Measure after the next nightly |
| --- | --- | --- | --- | --- |
| 1 Waiting reports wake no turn | Landed | 93dbdfe..64c5052 | replay: -739 turns a week (-36%) | report and untold turns a day |
| 2 Own stop/sleep keeps the session | Landed | 93dbdfe..64c5052 | tests | `layout.kept` share, first-request cache write |
| 3 Open-items list | Landed | 8ba0679..0fdebc8 | 726 of 1,310 sleep notes carry "owed" prose | that count; posts naming one subagent a day |
| 4 No refused posts | Landed | 0af7217..20852ed | replay: 112 refusals -> 50; 4 of Nov 19's 5 post | `chief.reply_too_long` a week |
| 5 No second copy of the prompt | Landed | 0fdebc8..6dacbcb | 33 KB (about 8k tokens) less a Chief turn, 15 KB less a subagent's first prompt | first-request cache write |
| 6 First reply sooner | chief-responsiveness lane | | | |
| 7 Landed work told in its turn | Built (sleep/stop refused once until named) | see commit | 176 of 382 landed reports told in the turn that saw them; told p50 23 s, p90 379 s | that share; report -> told p90 |
| 8 Keep cap | chief-responsiveness lane (160k) | | | |
| 9 No turn lost to a restart | No change needed | | Nov 12-19: all 14 restart-cut turns ran again (`RESUMED`); all 22 error-ended turns were retried (max gap 44 min, a model-endpoint wait) | |

Item 7 changed after a new measure: reports reach a turn in 0.5 s (p50), so the queue order was not the
cause; the turn that saw a landed report often ended with `sleep` and told it in a later turn.
