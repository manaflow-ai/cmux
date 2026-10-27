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

## Next

1. A `chief-replay` runner that runs each replay above with one command against a scratch home and
   prints one table.
2. The tool-list check for `spawn` and `tell`, with the trace turns that failed as its inputs.
3. The browser-argument replay.
