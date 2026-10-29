# Fast Chief iteration loop

Lawrence (Oct 25): "let's figure out how we can iterate on chief faster." The goal: change the
prompt or the host, then replay an eval in seconds, with the user's live Chief never touched.

## The loop

1. **A scratch Chief.** `cmux chief --chief-home /tmp/chief-scratch-X` starts its own daemon and
   brain. The TUI is the terminal client, and the scriptable verbs (`chief send --wait`,
   `chief wait`, `chief read --json`) drive it from a test (see `chief-tui.md`).
2. **A scratch memory.** `sqlite3 "file:LIVE?mode=ro" ".backup COPY"` copies a real memory without
   writing to it. Every replay reads the copy.
3. **Replays, one per weak spot.** Each replay takes recorded inputs, sends them through the
   *host's own code path* with a real model, and prints one rate. Run it once on the old code to
   get a red number and once on the new code to get a green number.
4. **Fixed-model unit tests** guard the code path (red, then green) and run in CI in less than 1 s.
5. **The fresh-Chief eval** (a651, `fresh-chief-eval.yml`, every 6 h) stays the end-to-end check
   of a new Chief.

## Weak spots

| Case | Replay | State |
| --- | --- | --- |
| Compactor refusals ("I can't write this memory line ...") | `optchat-host/examples/replay_compactions.rs` | Fixed on the host. The live memory keeps 984 old refusal lines, see below |
| Deferred tool "No such tool available" | Replay the turns that called `spawn`, `mcp__optchat__tell` or `bash` with a fixed model. Check that the turn's tool list holds them | Open: 11 trace hits from Oct 19 to Oct 25, for `spawn`, `tell` and `bash` |
| `cmux browser` argument errors (`--url` and other wrong forms) | Run the Chief's browser calls from its traces against `cmux browser --help`. Count the usage errors | Open |
| "Untested" landings | Look at the `work:` reports that say "landed". Flag the reports that give no test or run link | Open: a report check is the fix |
| Slow Cloud Chief | a664's timing marks (start, first token, turn) | 8621b40 is in prod but no real turn has run on it yet |

## Case 1: compactor refusals (Oct 25)

Data comes from the trace (`traces/*.jsonl` `node` events), joined with the node texts in a copy of
the default Chief memory:

- **Production, before the fix.** Haiku 5.5 nodes written as a refusal: 0.2% on Oct 19, 4.9% on
  Oct 20, 18% on Oct 21, 18% on Oct 22, 13% on Oct 23, and 11% on Oct 24 before 15:56. The memory
  holds 984 refusal nodes. 652 of them are original refusals (260 leaves and 392 merges). The other
  332 merges only copy a child's refusal.
- **Production, after the fix.** The prompt line "Never refuse" and the refusal retry
  (5d3d07cf64f) reached the installed host on Oct 24 at 15:56. From then on: 0 refusals in 424
  nodes.
- **Replay, current code.** Of 200 sampled original refusal nodes, 0 refused again (0 refusal
  replies in 410 Haiku calls). Of 20 control nodes, 0 refused.
- **Replay, prompt without the "Never refuse" line.** Of 40 sampled original refusal nodes, 0
  refused. A fresh call does not reproduce the refusal. The refusal comes from the state of the
  model or the session at that time, not from the input. The host must therefore handle a refusal
  whenever it occurs, and not depend on the prompt alone.

Fixes on the host (feat-cmux-next, a463c35b935):

- A refusal written as text in every try now goes to the fallback model (`claude-sonnet-5`).
  Before, only a `stop_reason: refusal` went to the fallback.
- When the fallback model refuses too, the input stands in as the node's text. For a merge, each
  child line gets half of the 512 bytes. Before, the second child was cut away.

Still open: the 984 old refusal lines in the live memory. The inspector's `rebuild` path
(`inspect/edit.rs`) can rebuild them. The order is the 652 original refusals first, then their
parents. This writes to the user's live memory, so it waits for the user's word.

## Trace metrics (Oct 27)

`measure/chief_health.py` gives the health of a real Chief home in about 1 s, no model.
Baseline, Lawrence's default Chief (copy of Oct 26 22:57), last 7 days:

| Number | Last 7 days | All time |
| --- | ---: | ---: |
| Messages the person typed (no acks) | 541 | 949 |
| Time to first reply, p50 / p90 | 25 s / 75 s | 24 s / 69 s |
| Replied within 10 s | 10.5% | 9.0% |
| No reply within 15 min | 4.4% | 2.7% |
| Turns cut by a server restart | 9 | 10 |
| Turns that ended in an error | 1.2% | 2.2% |
| Turn first token p50 / p95 | 2.9 s / 8.4 s | 3.2 s / 11.4 s |
| "No such tool" calls | 13 of 61,559 | 14 of 86,832 |
| `cmux` usage errors | 18 (3.1%) | 18 (1.7%) |
| Subagents without a workspace | 25 of 298 | 25 of 478 |

17 of the 18 usage errors are `browser right navigate --url`, which the show block taught
(fixed in d43a10946c6). The 2 "refusal lines" of all time are Chief's own Oct 13 reply
"Could you open the a12 link ...", kept verbatim: not refusals.

## Replays of real messages, evals 1 to 3 (Oct 27)

`measure/replay_cases.py` makes model cases from Lawrence's default Chief memory (Lawrence's
messages only; the cases stay outside the repo, mode 600). Rules only, no model judge. Gold
is what Lawrence accepted: Chief spawned within 15 minutes and his next message was no
correction. 12 dispatch and 12 feedback messages were sampled from 114 and 127 such
messages (seed 11); 1 was left out because its repo was named only in older memory. 4 rule
cases: links, short replies, Group lines, landing on feat-cmux-next.

Real brain (`chief_eval`, Opus 5.5, medium effort, sr2 gateway), 3 runs per case:

| Eval | Cases | Pass |
| --- | ---: | ---: |
| 1. Dispatch fidelity | 11 | 33/33 |
| 2. Feedback to action | 12 | 35/36 |
| 3. Rules stick | 4 | 12/12 |

The one failure used "hold" where the check wanted "holding": a check that is too strict, not
a Chief failure. Turn p50 13 s, cache hit 0.87.

What the first two runs taught about the cases, all fixed in the generator before the run above:

- The history lacked Chief's own earlier spawns, so Chief redid older asks first and
  sometimes skipped the new one. The history now shows them ("Started a12: Title").
- A check on the person's first five words verbatim failed on any paraphrase or fixed
  typo. Now: any one of up to 3 key words that the accepted task kept.
- A case whose repo was named only in older memory could not pass from its 8-message
  history, so it is left out.
- A spawn without a cwd fails on purpose. The host then runs it in the Chief's own folder,
  not the repo (2 of the 5 failures in run 2).

These cases are too easy to show a change in this form: they pass at 99%. Next, harder
sets: messages that Lawrence corrected (the regex finds about 10% of dispatches), rules
taught more than 100 messages before the request, and a fresh draw of seeds.

## Steer deadline, scratch test (Oct 27)

The question: a person's message that arrives while a turn runs is steered in, and when
Claude Code has not read it within 3 s (`STEER_DEADLINE`), the host interrupts the turn,
mid-tool. Is `OPTCHAT_STEER_DEADLINE_SECONDS=0` (wait for the next tool boundary) better?
Two scratch Chiefs (installed nightly host, default engine, same prompt), one per setting.
Live Chiefs untouched. Per trial: message A asks for a 25 s foreground command
(`python3 -c "time.sleep(25)"`), message B asks a sum 8 s later. 5 trials each.

| | 3 s (today) | 0 (next tool boundary) |
| --- | --- | --- |
| B answered | 4/5, in 9-10 s (one 79 s), one not in 150 s | 5/5, in 24-33 s (p50 26 s) |
| A finished | 1/5 (115 s) | 5/5 (32-41 s, p50 34 s) |
| Turns interrupted mid-tool | 5/5 | 1/5 (A still finished) |
| Chief's reason for a lost A | "the foreground command was rejected" (4/5, false: the host's own interrupt killed it) | none needed |

A first run with `sleep 25` did not reach the steer path: Claude Code refuses a foreground
sleep, so Chief ran it in the background and ended the turn. It still showed the follow-through
gap: "I'll post what it prints when it finishes" in 10 of 10 trials, kept 1 time; with the 3 s
deadline the interrupt also killed 2 background jobs.

Reading: 3 s answers the quick question about 15 s sooner, and loses the running work
nearly every time, with a false explanation. A middle way to test next, with no host message
(the host's "Chief is busy" receipt was removed on Lawrence's word, "no fake messages"): wait
for the next tool boundary, and interrupt only a tool call that is still running after a
longer limit (for example 30 s). n=5 per setting, one model: not enough to change the
default alone.

## Next

1. A `chief-replay` runner that runs each replay above with one command against a scratch home and
   prints one table.
2. The tool-list check for `spawn` and `tell`, with the trace turns that failed as its inputs.
3. The browser-argument replay.
