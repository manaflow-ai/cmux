# The chat simulator

Leo, 2026-11-21: "you guys need to analyze simulated behaviour. we can do this without any real agent
sessions, just simulated ones. ... you can even replay my transcript. ... we can just have simulations of
things that go monstrously long".

The simulator plays a chat through the pane's own code on virtual time, with no agent and no daemon:

- the records acpmux would write (`EventRecord`s) are folded one at a time by the pane's real reducer
  (`AcpmuxDirectClient.replay` / `seekReplay`, as session replay does);
- each snapshot is shaped by the real turn view (`turnViewFrom`, built on the last, as `App.tsx` does) and
  placed by the real layout (`layoutConversation`, the gap over each row the virtual stack draws);
- after every step it probes the drawn rows and checks three rules, and writes one JSONL line per step.

It runs under plain `bun` (no DOM), so it scales: a 1,800-turn run is 43k steps, 10k+ rows and 40 hours of
virtual time.

| File                                | What                                                                                                                                                                                                                                                   |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `script.ts`                         | The scenario language: `sim(name, about).prompt(..).think(..).tool(..).say(..).turnEnd()`, plus `incoming` (another agent's notice or message), `background`, `subagent`, `compaction`, `reader` (scrolling), `wait`, and `record` for any raw record. |
| `scenarios.ts`                      | The named scenarios (`SCENARIOS`) and `longRun(turns)`.                                                                                                                                                                                                |
| `run.ts`                            | `runSimulation(scenario, options)`: the run, the probes and the rules. `summarize(result)`.                                                                                                                                                            |
| `sanitize.ts`                       | Makes a recorded chat safe to commit (below).                                                                                                                                                                                                          |
| `../../../../scripts/chat-sim.ts`   | The command line.                                                                                                                                                                                                                                      |
| `../../../../test/chat-sim.test.ts` | The tests: every scenario, a sanitized replay, the sanitizer, a long run.                                                                                                                                                                              |

## Run it

From `webviews/` (`export PATH=$HOME/.bun/bin:$PATH` if bun is not on PATH):

```sh
bun scripts/chat-sim.ts --list                                 # the scenarios
bun scripts/chat-sim.ts incoming-notice-turn                   # one scenario
bun scripts/chat-sim.ts --all                                  # every scenario
bun scripts/chat-sim.ts incoming-notice-turn --trace /tmp/s.jsonl   # and its per-step trace
bun scripts/chat-sim.ts --long 1800 --trace /tmp/long.jsonl    # 10k+ rows, about 40 h simulated (about 90 s)
bun test test/chat-sim.test.ts                                 # the tests (CHAT_SIM_LONG=1 for the 10k-row one)
```

Each run prints a summary line (steps, rows drawn, rows before the turn view folds them, virtual and wall
time, violations by rule, and the mid-turn folds the rules allow) and one line per distinct violation
(`--show N` lines at most, default 20). Exit status 1 means a violation.

## In Chrome

The model run places rows with the pane's layout but guesses each row's height (one line, or a reply's
lines). The browser lane draws every step in Chrome with the real `VirtualTranscript` and the pane's CSS
(motion off), reads each drawn row's box (`.acpmux-row[data-row-id]`), and checks the same rules on the
drawn gaps, plus `b-mid-turn-shrink`: a row of a running turn drawn 12px or more shorter than at the step
before, with its own fold unchanged.

```sh
CMUX_BROWSER_TESTS=1 bun test test/chat-sim-browser.test.ts                       # every scenario and the replay
CMUX_BROWSER_TESTS=1 CHAT_SIM_SCENARIOS=incoming-notice-turn,long:40 bun test test/chat-sim-browser.test.ts
CMUX_BROWSER_TESTS=1 CHAT_SIM_OUT=/tmp/chrome.json bun test test/chat-sim-browser.test.ts   # results as JSON
CMUX_BROWSER_TESTS=1 CHAT_SIM_DUMP=incoming-notice-turn:30 bun test test/chat-sim-browser.test.ts  # the boxes at a step
```

It needs Chrome (Linux, a Freestyle VM or CI; never on a Mac). A step costs two frames, so the replay
(3,561 steps) takes a couple of minutes.

## Replay a real chat

```sh
bun scripts/chat-sim.ts --replay ~/.acpmux/sessions/<id>                    # a session's records, as recorded
bun scripts/chat-sim.ts --replay ~/.acpmux/sessions/<id> --from 2000 --to 9000
bun scripts/chat-sim.ts --replay ~/.acpmux/sessions/<id> --sanitize test/fixtures/chat-sim/NAME.ndjson
bun scripts/chat-sim.ts --replay test/fixtures/chat-sim/replay-lane-session.ndjson
```

`--sanitize FILE` writes a fixture safe to commit, and runs it. It keeps the chat's shape (which records,
in order, how far apart in time, how long each text is, where its lines and Markdown marks fall) and drops
what it said: every word and number becomes a stand-in of the same length picked by a hash, so an id that
recurs (a call and its result) still pairs. Only short enum-like values under the keys the reducer branches
on (`kind`, `status`, `sessionUpdate`, `state`, ...) stay. The agent's stdin (`out` records), the harness's
token stream and the session's tags and config are dropped. Look over a fixture (`grep` it for names and
hosts) before committing it all the same.

A sanitized replay is close to its raw chat, not identical: the fixture here (a lane chat's first 9,000
records) draws 74 rows and 9 `a-head-gap` violations sanitized, and 77 rows and 12 raw (99 before folding both).
Some of the pane's text parsing (an incoming message's sender, a background task's summary) reads words the
sanitizer replaces. Compare the two with `--replay DIR` and `--replay DIR --sanitize OUT` when it matters.

## Sweep every chat on a machine

```sh
bun scripts/chat-sim.ts --sweep ~/.acpmux/sessions --jobs 4
```

This replays every chat in the folder, each in its own process and `--jobs` at a time. It prints one line per
violation class: the rule and its detail, with the row ids, turn numbers and times taken out and the gaps kept.
Each line also gives how many rows broke it, in how many chats, and one chat and step to replay. Classes found
in many chats come first. A lane VM's 278 chats (7.4 GB of records) take about 20 minutes at 4 jobs.

The first sweep (2026-11-22) found these classes:

- Another agent's message opening a turn sat 16 px under the last reply of the turn before (37 chats). Fixed:
  transcriptGrid.ts `MARK_TOPS_TURN`.
- Three classes of simulator false positives, now read as the pane means them:
  - A steer, a message that comes in while the turn runs, was counted as a new turn.
  - "Working for" drawn over the message that opened its turn had no rule of its own.
  - Codex messages folded under "Worked for" while the final answer streamed. That fold is by design, and its
    verdict is now `final-answer`.

## Write a scenario

```ts
"my-case": () => {
  const b = sim("my-case", "One line: what it reproduces.");
  b.prompt("Fix the flaky test.");
  b.think("Reading the helper.").tool("rg -n retry src", { ms: 800 });
  b.say("Found it.").turnEnd();
  b.wait(30_000).incoming("hq#1 merged", { kind: "notice", fromName: "merge-bot" });
  b.tool("git pull", { open: true });   // a call left running; end it later with b.toolEnd("call-3")
  b.reader({ scroll: "top" });          // the reader scrolls up (held folds apply while scrolled up)
  return b.turnEnd().build();
},
```

Every method takes the ms before it (`after`), so a scenario is its own clock. `record(dir, kind, msg)` is
the escape hatch for any record acpmux writes.

## The rules

- **(a) gaps**: `a-turn-gap`: a turn's opening row stands at least the turn gap (32) under the turn before
  it, or the block gap (24) when it is another agent's line (a notice or message; transcriptSpacing.ts
  `footer-to-received`, by design). `a-head-gap`: the turn's head (its "Working for" / "Worked for" line, or
  the first row under its opening row) stands at least the block gap (24) under the opening row.
- **(b) folds**: no row folds (leaves the drawn rows, or its fold closes) before its turn's `turn_result`.
  Allowed, and counted in the summary as "mid-turn sibling folds": a finished run of calls (and a
  compaction line inside it) closed with a reply of the same running turn under it: the `runs` arm of
  live-turn-work, where a run stays open until the agent's next paragraph (#48597). A run closed by the
  next call alone is a violation. A reply whose text reappears in another row is `remapped`, not folded.
- **(c) stillness**: no row two or more turns back is rebuilt (a new row object with the same id, version
  and fold) when nothing changed it. Live lines are exempt.

## Read the trace

One JSON object per step:

```json
{
  "scenario": "incoming-notice-turn",
  "step": 24,
  "t": 38400,
  "label": "thought delta",
  "seq": 24,
  "working": true,
  "turn": 2,
  "turnEnded": false,
  "rowCount": 5,
  "folds": [],
  "rerendered": [],
  "violations": [
    {
      "rule": "a-head-gap",
      "rowId": "working-user-22",
      "detail": "working heads turn 2 0px under its opening user (want >= 16)"
    }
  ],
  "rows": [
    {
      "id": "user-22",
      "kind": "user",
      "turn": 2,
      "gap": 24,
      "fold": "",
      "opens": true,
      "received": true,
      "text": "hq#16160 merged"
    },
    { "id": "working-user-22", "kind": "working", "turn": 2, "gap": 0, "fold": "", "head": true }
  ]
}
```

`t` is ms of virtual time from the first step. `rows` (each drawn row's id, kind, turn, the gap over it, its
fold `open`/`closed`, and the flags `opens`, `received`, `head`, `live`) is written while the chat has at most
`--rows-up-to N` rows (default 400). `folds` lists every fold at that step with `beforeTurnEndMs` (how long
before its turn's end it came) and its verdict. `jq 'select(.violations|length>0)' /tmp/s.jsonl` lists the
steps that broke a rule.

The steps a run probes are those where something changed: a step that leaves the rows over the first
changed row as they were (the same objects) probes only from that row down, so each step costs about the
same on a 10k-row chat.
