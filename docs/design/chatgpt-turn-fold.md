# How chatgpt.com folds a finished turn

Read on 2026-11-10 and 2026-11-11 in a cmux browser tab, signed in, on a chat whose turns ran tools.
Used for the cmux-next agent pane and Home Chief chat ("Worked for" fold in
`webviews/src/agent-session/acpmux/conversation/turns.ts`).

## Finished turn, closed (the default)

- One row: `Worked for 23s` (or `Thought for Ns` when the turn only reasoned), 16px, weight 400,
  secondary text color (`rgb(175,175,175)` in dark), 24px tall, a chevron icon after the text.
- Under it: only the final answer. Every tool call, every "Ran 2 commands" line, every thinking
  block and every short progress note ("Running the first six-second wait.") is hidden.
- The hidden rows are not in the DOM at all while closed (unmounted, not `display:none`).

## Finished turn, opened

- The rows mount in time order: progress notes ("ChatGPT said: ...") and tool lines ("Waiting six
  seconds"), then the answer stays below.
- Motion: the chevron rotates in 150ms `cubic-bezier(0.4, 0, 0.2, 1)`; the revealed block fades and
  grows in 300ms `cubic-bezier(0.19, 1, 0.22, 1)` (expo out). No bounce.

## Running turn

- One live status line in the same place as the closed row. Its text replaces itself as the work
  moves on (it does not stack lines). The answer streams below it. When the turn ends the line
  becomes `Worked for Ns`, closed.

## What is remembered

- Nothing. After a reload every "Worked for" is closed again.

## Where cmux differs on purpose

- A reply the agent wrote to the person between tool runs stays in sight in a closed fold (an
  earlier user rule: an intermediate message must never get lost). ChatGPT hides those notes too.
  Tool calls, progress and thinking are hidden, as on ChatGPT.
- Leo, 2026-11-13: "a message was folded i think erroneously". An answer with paragraphs and a
  table followed by a tool and a short receipt must keep the answer visible. A later "I sent it"
  does not replace even a one-sentence answer. The default `answer` arm stays the default.
- `isTakeaway` preserves structured text, questions, links, text over 160 characters, more than
  three lines, and prose that is not recognizable short work narration. Only up to two short
  narration sentences ("Let me check…", "Running the tests.") fold. The same classifier feeds
  live runs and completed turns, including cold transcript reloads.
- Detector: `webviews/test/answer-before-tool-replay.test.ts` exercises answer → tool → receipt
  through the direct client while live, completed, opened, and reloaded. The
  `agent-pane.substantive-answer-fold` gallery covers the table, work narration, and answer-only states.

## Reference shots

The page screenshot verb in cmux needs a person's click, so no shot was taken by the agent. The
numbers above come from the page DOM, computed styles and `document.getAnimations()`.
