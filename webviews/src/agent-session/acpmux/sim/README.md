# The chat simulator

Leo, 2026-11-21: "you guys need to analyze simulated behaviour. we can do this without any real agent
sessions, just simulated ones. ... you can even replay my transcript. ... we can just have simulations of
things that go monstrously long".

The simulator plays a chat through the pane's own code on virtual time, with no agent and no daemon:

- the records acpmux would write (`EventRecord`s) are folded one at a time by the pane's real reducer
  (`AcpmuxDirectClient.replay` / `seekReplay`, as session replay does);
- each snapshot gets the running tray's subagent lines (`withSubagentLines`, as `App.tsx` does), is shaped
  by the real turn view (`turnViewFrom`, built on the last, as `App.tsx` does) and placed by the real
  layout (`layoutConversation`, the gap over each row the virtual stack draws);
- after every step it probes the drawn rows and checks four rules, and writes one JSONL line per step.

It runs under plain `bun` (no DOM), so it scales: a 1,800-turn run is 43k steps, 10k+ rows and 40 hours of
virtual time.

| File                                    | What                                                                                                                                                                                                                                                                                                                                    |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `script.ts`                             | The scenario language: `sim(name, about).prompt(..).think(..).tool(..).say(..).turnEnd()`, plus `incoming` (another agent's notice or message), `message` and `steer` (mid-turn), `background`, `subagent`, `compaction`, `plan`, `permission`, `retry`, `stop`, `fail`, `reader` (scrolling), `wait`, and `record` for any raw record. |
| `scenarios.ts`                          | The named scenarios (`SCENARIOS`) and `longRun(turns)`.                                                                                                                                                                                                                                                                                 |
| `map.ts`                                | The map: every case, what is expected of it, and its check (below).                                                                                                                                                                                                                                                                     |
| `run.ts`                                | `runSimulation(scenario, options)`: the run, the probes and the rules. `summarize(result)`.                                                                                                                                                                                                                                             |
| `sanitize.ts`                           | Makes a recorded chat safe to commit (below).                                                                                                                                                                                                                                                                                           |
| `../../../../scripts/chat-sim.ts`       | The command line.                                                                                                                                                                                                                                                                                                                       |
| `../../../../scripts/chat-sim-watch.ts` | Watch a run in Chrome with motion on: video and screenshots ("Watch it").                                                                                                                                                                                                                                                               |
| `../../../../test/chat-sim.test.ts`     | The tests: every scenario, a sanitized replay, the sanitizer, a long run.                                                                                                                                                                                                                                                               |

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

## Watch it

Leo, 2026-11-22: "offline as in it doesnt actually need a proper agent response. it just simulates it. based
off like my transcript history. that's offline".

`scripts/chat-sim-watch.ts` plays a scenario, a long run or any recorded chat (a fixture or a session
directory) in headless Chrome with the real `VirtualTranscript`, the pane's CSS and its motion **on**, on
scaled real time, so streaming text, tool calls, subagents and folds move as they do in the pane. It writes a
video (`--video`, WebM) and screenshots (`--shots DIR`) at every turn's start and end, at the end, and every
`--shot-every N` steps, plus `result.json` (steps played, turns, model-rule violations).

```sh
bun scripts/chat-sim-watch.ts incoming-notice-turn --video /tmp/sim.webm --shots /tmp/sim-shots
bun scripts/chat-sim-watch.ts --long 3 --speed 2 --video /tmp/long.webm --shots /tmp/long-shots
bun scripts/chat-sim-watch.ts --replay test/fixtures/chat-sim/replay-lane-session.ndjson --limit 800 --speed 8 --video /tmp/replay.webm
bun scripts/chat-sim-watch.ts --replay ~/.acpmux/sessions/<id> --from 2000 --to 3000 --shots /tmp/mine
```

`--speed X` runs virtual time X times faster; `--max-gap MS` (default 1500) caps any one real wait, so an
idle hour in a transcript does not play as one; `--max-seconds S` (default 600) stops the run there, so a
huge fixture cannot run forever; `--width`/`--height` size the pane (720 by 900); `--motion off` draws rows at
rest, as the rule checks do. The page's entry is `window.__chatSim.watch({ name | records, speed, ... })`
in `test/browser/chat-sim.harness.tsx` (the page is handed the records, so any file works); `run` and `at`
are unchanged.

Like the browser lane it needs Chrome, so not on a Mac: run it on a Linux VM with Chrome, or through the fleet:

```sh
cd webviews && bun scripts/chat-sim-watch.ts --long 3 --video /tmp/long.webm --shots /tmp/long-shots   # on the VM
cmux-ci test --setup playwright --not-tests --artifact webviews/sim-out -- 'cd webviews && bun scripts/chat-sim-watch.ts --long 3 --video sim-out/long.webm --shots sim-out/long'
```

## Replay a real chat

```sh
bun scripts/chat-sim.ts --replay ~/.acpmux/sessions/<id>                    # a session's records, as recorded
bun scripts/chat-sim.ts --replay ~/.acpmux/sessions/<id> --from 2000 --to 9000
bun scripts/chat-sim.ts --replay ~/.acpmux/sessions/<id> --last 3000
bun scripts/chat-sim.ts --replay ~/.acpmux/sessions/<id> --sanitize test/fixtures/chat-sim/NAME.ndjson
bun scripts/chat-sim.ts --replay test/fixtures/chat-sim/replay-lane-session.ndjson
```

`--from` and `--to` include both sequence numbers. `--last N` selects the last N sequence
numbers in the log and can be combined with either bound. For a split acpmux log, the simulator
probes segment headers and parses the segments that cover the range. A tail replay can start
directly in the last segment.

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

## Capture a reported breakage

Leo, 2026-11-22: "you guys need to be able to rapidly pull up and develop against these scenarios, just like
the offline simulator."

```sh
bun scripts/chat-sim.ts --capture <chat> --window "2:05PM NOV 22 TO 2:11PM" --name leo-2205-burst
bun scripts/chat-sim.ts --capture <chat> --report "why did it collapse"     # the minutes before that prompt
bun scripts/chat-sim.ts --capture cosmic-gray/<name> --window "22:05Z-22:11Z" --out /tmp
```

`<chat>` is a session folder, an id or name under `~/.acpmux/sessions`, a `HOST/NAME` on a peer (below), or
anything else `acpmux session export` resolves. The window is read on his clock (America/Los_Angeles; `--tz` changes it)
unless it says `Z` or is ISO: `2:05PM`, `2:05 pm nov 22`, `14:05`, `22:05Z`, `A to B`, `A-B`, `A..B`. One time
is the `--minutes` (6) before it. `--report TEXT` takes the window ending at his last prompt holding TEXT.
The records kept reach back to the start of the turn running when the window opened (`--no-lead` keeps only
the window), so the reducer has that turn's rows when the window's first record lands.

It writes `<out>/<name>.ndjson`, sanitized as `--sanitize` does (default out: `test/fixtures/chat-sim`), and
`<name>.json` beside it (the window, the build the chat ran, the counts). Then it plays the fixture the ways
the live pane read it, each in its own process: whole; its last 400 records, as a pane opening the chat
reads one page; and from halfway, as a reconnect. It prints each read's violations by rule, the first
`--show` (5) with the time on his clock they happened. A capture takes well under a second, then
`--replay FIXTURE --trace FILE` is the loop to develop against.

### Replay every reported chat

`bun scripts/chat-sim.ts --reported` replays every committed `.ndjson` fixture. Each capture's
`.json` sidecar records how many distinct rows broke each rule in its whole replay. The command
prints the change for each rule (e.g. `a-head-gap 9 -> 0`) and exits 1 if any count increased.
After inspecting the changes, run `--reported --update` to write the new counts. That also records
an initial baseline for older fixtures with none and preserves their capture metadata.

### Capture from another host

`--capture HOST/NAME` reads a chat on a peer over the mesh hub, so a lane VM captures a chat on another
machine without running anything there. The hub does not carry `acpmux session export`, so it reads
`acpmux session history HOST/NAME --json` (one summary per turn: its prompt's seq and time) to find the turn
running when the window opened, then `acpmux session tail HOST/NAME --json --since SEQ` from that turn's
prompt, stopping at the first record past the window. The records go through the same range, sanitize and
replay as a local capture. `--report TEXT` matches the start of a prompt (the history cuts prompts short).
Each acpmux read is bounded (`--timeout S`; 120 s for the history, 600 s for the tail); a hub error prints
one line and exits 2, with no retry. A host the hub lists only via relay fails every read until
cmux#48249: capture on that host instead.

The tail is the cost: about 33 KB/s over the hub (2026-11-23, a lane VM reading a peer Mac: 1517 records,
0.97 MB, 29 s), so a window late in a long turn reads the whole turn up to it.

## Keep it current

```sh
bun scripts/chat-sim.ts --drift ~/.acpmux/sessions --days 7
```

The simulator only checks what it plays. `--drift` lists the record kinds the pane reads (a kind named as a
string in `src/agent-session`) that recent chats on the machine sent and that no committed fixture or
scenario plays, with how many chats sent each and the newest. It then names the `--minutes` (10) span of
one chat holding the most of them, as a `--capture` command to run. `--all-kinds` lists the kinds the pane
does not read too. It exits 1 while any kind is missing. Run it after a protocol change and capture what it
names. `--json` prints the same answer as one object.

It also runs on its own: a fleet timer runs `--drift --days 1 --json` over a session host's chats every 6
hours, from `feat-cmux-next` as merged, and keeps each answer with the kinds new since the pass before.

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

## The map

Leo, 2026-11-22: "there are probably more bullshit scenarios. we need to map them all out and note what
expected behaviours are for all."

`map.ts` is that map: one entry per way a chat's display has gone wrong, or plausibly can. Each says what
happens (`when`), what went wrong (`wrong`), what the reader should see (`expected`), names the scenario that
plays it, and checks the expected behaviour on that scenario's run. `EVERYWHERE` holds what every chat keeps
whatever it plays: one live line and it is last, no two rows with one id, one footer a turn, a prompt never
taken away, rows of a running turn only append, a chat at rest ends on its footer.

```sh
bun scripts/chat-sim.ts --map              # each case: holds, open, not played, or BROKEN (exit 1)
bun test test/chat-sim-map.test.ts         # the same, plus every scenario read from halfway and at 320 wide
```

An entry with `open` is a known hole. With a scenario and a check, it is an oddity the pane still has: its
test is marked failing, so the fix turns it red until `open` is taken away. With no scenario, nothing plays it
yet. The test also holds the two lists together: a scenario with no entry, or an entry naming a scenario that
is gone, fails.

To add a case: write the scenario (below), add its entry with a `check` that returns one line per way the
expected behaviour does not hold, and run `--map`. A check reads the run's steps (`run.traces`, each with its
drawn rows), so it can say "at every step between these two records" as easily as "at the end".

## Start at the interesting part

```sh
bun scripts/chat-sim.ts --replay test/fixtures/chat-sim/replay-lane-session.ndjson --start-at 50
bun scripts/chat-sim.ts --replay ~/.acpmux/sessions/<id> --seek-to-event 4200 --lead 2
```

`--start-at S` starts S seconds of virtual time into the scenario; `--seek-to-event SEQ --lead S` starts S
seconds before the first record at or after SEQ. Every step before the start is still applied (the reducer
and turn view see every record, so the chat there is exact, not a fast-forward); the trace and the
violations begin at the start. `seekPlan` (sim/seek.ts) is the split: the steps to apply at once and the
rest's delays. In Chrome, `window.__chatSim.seek(name, { startAtMs } | { seekToSeq, leadMs })` applies the
prefix, draws that state in one frame and returns `start`, so a recorder plays from there and a clip shows
only the part that differs (keep proof clips under about 15 s).

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
- **(b) folds**: no row folds (leaves the drawn rows, or its fold closes) before its turn's first end record (`turn_end`, or `turn_result` when no end was recorded).
  Allowed, and counted in the summary as "mid-turn sibling folds": a finished run of calls (and a
  compaction line inside it) closed with a reply of the same running turn under it: the `runs` arm of
  live-turn-work, where a run stays open until the agent's next paragraph (#48597). A run closed by the
  next call alone is a violation. A reply whose text reappears in another row is `remapped`, not folded.
- **(d) received lines**: `d-received-gap`: another agent's line (a notice or message) among tool rows sits on
  their pitch: flush under its own turn's "Working for" / "Worked for", at most 8 from a tool row, a run line
  or another received line next to it, and the live line a step's gap under it, never a prompt's room (Leo,
  2026-11-22: "sometimes you get these way-too-big gaps. i think it's the message recieving not properly
  getting treated like the tool call ish thing it should be and instead as if it were a message?").
- **(c) stillness**: no row two or more turns back is rebuilt (a new row object with the same id, version
  and fold) when nothing changed it. Live lines are exempt.
- **(d) the 22:05Z burst** (Leo's chat, 2026-11-22 22:05-22:11Z, `test/fixtures/chat-sim/leo-2205-subagent-burst.ndjson`):
  `d-started-pill`: a "started working" line names at most `STARTED_LINE_NAMES` (3) subagents, each by name,
  and none whose start the pane never read (one first met through progress, its spawn before the page);
  `d-started-lines`: one start line a turn (later starts join it); `d-blank`: once rows are drawn, the chat
  never draws none; `d-shift`: a settled row (two or more turns back, not live) keeps its viewport position after the transcript anchors a prepend;
  `d-action-only`: a turn that ended draws more than its prompt and its action row; `d-steer-order`: no
  row of a steer's turn that came after the steer is drawn above it; `d-row-key`: no two drawn rows share a
  React key (`rowFrameKey`): React keeps one element for both and the other stays painted where it was placed
  (cmux#59809, a second "Worked for" of one background turn over a bullet of the reply).
- **(i) bubble integrity** (integrity.ts), on each turn's rows at its `turn_result` and at the run's last step
  (Leo, 2026-11-22: "you also basically said the same thing", images/1157.png; "ok, well. this happened again",
  1158.png): `i-split-bubble`: two reply rows of one message (same `messageId`), or the first cut inside an
  open span, with nothing but a fold or header between them (a "Worked for" whose two sides are one message);
  `i-repeated-paragraph`: a paragraph of 40+ characters drawn twice in one turn (a row repeating its own
  paragraph, or a row whose text is another's suffix); `i-unclosed-markdown`: a settled reply left open inside
  `**`, a fence, `$$` or an inline backtick; `i-placeholder-after-end`. The CLI exits 1 on any of them, and
  `--replay DIR --integrity` runs them alone on a recorded chat.

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
    {
      "id": "working-user-22",
      "kind": "working",
      "turn": 2,
      "gap": 0,
      "fold": "",
      "head": true
    }
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
