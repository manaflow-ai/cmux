# Composer hat: calm under bursts of calls

Leo, 2026-11-22: "the animations for when tool calls arrive/switch/counts come came from me initially
saying "hey i like claude code when it goes from thinking to tool calls then back to thinking etc" but
at this point im not even entirely sure if you guys are necessarily faithfully following it for the
thinking. i feel like it could be improved. regardless, porting all of that into the composer hat is...
interesting. but it's not entirely great. the swapping gets jarring. it's too adhd-ish. you need to
think hard about the various cases, various types of numbers, all that. perhaps there is a case to be
made for e.g. we dont show the exact calls, ever, at the top. then we therefore understand what will
pop up as they come. therefore we dont have humongous swings in text size that our yet-incapable
animation system cannot represent nicely, likewise with huge churn in numbers and symbols and messages
being sent."

## 1. The reference: Claude Code's own thinking -> tool -> thinking

This was recorded on 2026-11-22 with Claude Code v2.1.330 (Opus 5.5) in a 140x45 tmux pane, capturing a frame every
83 ms. The scenarios were: thinking only, one call, five sequential reads, six parallel shell calls, a 25 s command, a
background subagent, a failing call, and an interrupt.

- **One status line per turn, above the input. It never names a call.** The line reads
  `<glyph> <Verb>… (<N>s · ↓ <T> tokens[ · thinking])`. The verb is one random word chosen per turn, and it
  stayed the same through every thinking -> tool -> thinking switch, a burst of 6 parallel calls, 5 calls in a row,
  an error and a 25 s tool. The verb's *colour* is all that marks the phase: a shimmer while waiting for the first
  token, steady while thinking, and a 2 s pulse from the first call to the end of the turn.
- **Calls are rows in the transcript, above the line.** While a call is being written, one row counts up in place:
  `Running 2 shell commands…` and so on up to 6. When the call finishes, one summary row appears ("Ran 6 shell
  commands", "Read 1 file · 1 failed"). Each call's timer is on its own row (`· 2s` from about 2.7 s), never on the
  status line.
- **Numbers:**
  - The elapsed time counts the whole turn in whole seconds, and calls never reset it.
  - Tokens count up over the turn and hold still while a tool runs.
  - The `· thinking` label becomes `· thought for 1s` for about 2 s, then goes away.
- **Width:** the `<glyph> <Verb>… ` prefix is fixed for the turn. Only the grey bracket after it grows.

## 2. What we do differently today

| Surface | Today | Claude Code |
|---|---|---|
| Live line (conversation/Thinking.tsx) | Names the newest call ("Reading a.ts", "Running git status"), then back to "Thinking". Every change rolls the whole line, and its width changes with it | Never names a call. The verb holds for the turn and only its colour changes |
| Live line clock | Per stretch ("Thinking 12s"), with the turn's total after a step | One turn clock that never resets |
| Live line tokens | Not shown live (`liveLineTokens` experiment) | Shown live, and held still while a tool runs |
| Hat, lone subagent | Its exact latest call ("Edit trayMotion.tsx", then "Grep latestLine") slides in on every call, and the cell's width slides with it | Not applicable. The subagent's footer row reads its task, `10.9k tokens` and its time |
| Hat, many subagents | Each line's exact latest call, inline, sliding in on every call | Not applicable |
| Hat counts | Per kind ("3 subagents · 2 commands"), which change only when an item starts or ends; a workflow's "2/5 agents" | Not applicable |

Tokens and call counts already stay out of the hat (`subagentProgress(..., { usage: false })`). That leaves
the exact step text as the one thing in the hat that changes on **every call**. In a burst of 50 calls 60 ms apart,
it changes about 20 times a second (the slide takes 120 ms), with widths ranging from "Read a.ts" to a 60-character
command.

## 3. Cases and numbers

The slot is what the hat says a running subagent is doing now. Each case below lists how often the slot's content
and width change under each arm.

| Case | exact (before) | phase (default) | quiet | sampled |
|---|---|---|---|---|
| Thinking, no call yet | Its last words, or nothing | "Thinking" | nothing | its last words |
| One call | 1 change, new width | 1 word change, same width | none | 1 change, same width |
| Burst of 5 reads | 5 changes, 5 widths | 1 change ("Reading"). Read and Grep are both "read" | none | 1–2 changes |
| Burst of 50 mixed | about 50 changes, constant width churn | One change per 1.6 s at most, among 2–3 words | none | One change per 2.5 s at most |
| Parallel subagents | Every line churns on its own | Each line changes at most once per 1.6 s, and its width never changes | none | Every 2.5 s, per line |
| Subagent spawning subagents | "Agent" or its prompt title | "Delegating" | none | sampled |
| Long-running command | The command, constant | "Running", constant | none | The command, constant |
| Compaction | Not a subagent step. The live line says it | Same | Same | Same |
| Queued or steered messages | Not in the slot. They are in the composer queue | Same | Same | Same |
| Error or retry | The state column says Failed or Retrying | Same. The slot is hidden while retrying | Same | Same |
| Idle | The line is gone, or reads Done | Same | Same | Same |

These numbers in the hat remain, and each one is bounded:

- **Kind counts** ("3 subagents running · 2 commands") change only when an item starts or ends. Only their changed
  digits roll (`steadyCounts`).
- **The header's words and "+N more"** (the newest names, each kind's count) are held 1.6 s, as the step is
  (`Dwelt`/`useDwell`). Twenty subagents joining in a burst used to be twenty changes in 1.3 s; now it is one.
  `feel-composer-hat.test.ts` holds this on `agent-pane.composer-hat-head`'s `calm` variant: a line stays up at
  least 1500 ms, at most 0.67 swaps a second, no width changes.
- **Workflow agent counts** ("2/5 agents") change once per agent, not per call.
- **Elapsed time** ticks once a second in tabular figures (`Elapsed`). Its width changes only where the format grows
  (59s -> 1m 0s), at most once a minute.
- **Tokens and call counts** are never in the hat (`usage: false`). The opened line's details and Session Info show
  them.

## 4. The arms (hatStep.experiment.ts)

- **phase** (Leo's proposal, the default): one word for the kind of call, from a short fixed list.
  - The words: Thinking, Reading, Searching, Editing, Running, Fetching, Delegating, Working.
  - All the words are stacked in one grid cell, so the slot is always as wide as the widest word in the pane's
    language.
  - A word stays at least 1.6 s; a change during that time waits, and only the newest one shows.
  - A change cross-fades in place: no roll and no slide.
  - The kind comes from acpmux: the ACP kind of the subagent's own call, or `actionKind` (`tool_kind`) on Claude's
    task progress. React only turns it into a word.
- **quiet**: no step at all. Nothing in the hat moves per call. This loses the sense that work is happening, which
  is what the phase word keeps.
- **sampled**: the exact call, at most one change per 2.5 s, in a 22ch slot that cuts it off. Its content still
  changes and is often cut mid-word.
- **exact**: the old behaviour, kept for comparison.

The phase arm wins on all three of Leo's points:

- He knows what can appear, because the vocabulary is fixed.
- The width never swings.
- The churn is bounded at one change per 1.6 s per line.

It is also the closest to the reference: Claude Code keeps the status line still and leaves the calls themselves to
the transcript.

## 5. The live line (not changed here)

Our live line names the newest call and rolls on each one. Claude Code's never does. Changing that would reverse a
decision Leo made himself (the Codex-style live line, `oneRowPerCall`), so it is a question for him and is left out
of this change.
