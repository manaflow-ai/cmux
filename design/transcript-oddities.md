# Transcript oddities (agent chat)

A living list of everything odd the agent chat transcript does: what the reader sees, how to
reproduce it, why it happens, and the PR that fixes it. Add a row when you see one; never fix one
without a deterministic repro and a number.

Leo, 2026-11-21, on a reply that never drew: "i wonder if there's not great stuff inside of
cmux-next's tools/skills/whatever say the wrap up or whatnot where you guys somehow ignore things?
or things dont get rendeed?" And on how these get fixed: "we can't afford to have these thrown
together".

Paths are under `webviews/src/agent-session/acpmux/`. Motion ordering (which animation plays when,
O1 to O30) has its own map, `design/chat-animation-ordering-map.md`; this page links to it instead
of repeating it.

## How a reply reaches the screen

A reply is lost at one of four stages. Each oddity below names its stage.

| Stage | Code | What can lose a reply |
|---|---|---|
| 1. Events to rows | `direct.ts` (`reduce`, `OrderedRows`) | a row tagged to the wrong owner (`inBackground`), a segment cut in two, a row never made |
| 2. Rows to turns | `conversation/turns.ts` (`turnViewFrom`, `shapedTurn`, `shapeTurn`) | the wrong row picked as the answer (`answerAt`), a reply folded as narration (`isTakeaway`), a row hidden behind its owner (`hiddenInBackground`) |
| 3. Turns to placed rows | `VirtualTranscript.tsx`, `placedHeightIndex.ts`, `model.ts` (`fallbackRowHeight`) | a height estimate that differs from the drawn height (a gap or an overlap), a row outside the mounted window |
| 4. Placed rows to pixels | `conversation/turnEndFold.ts`, `tailGlide.ts`, `followChase.ts`, `fold.ts`, `conversation.css` | a row drawn away from its place while a fold or glide plays, a row left at opacity 0 |

Owners of a row, as stage 1 decides them:

- **A prompt's turn**: from a `user_message` that opens a turn to its `turn_result`. A steer
  (`steer: true`) stays in the running turn; one the agent never read is carried to the next
  (`turn_started.carried`).
- **A background turn**: between two `background_turn` records, for a turn Claude Code ran on its
  own (acpmux writes the records, `cmux-tui/crates/acpmux/src/hub/background_turn.rs`), or the turn
  a background command's finish opens (`bg-done-<task>`, which the pane brackets itself,
  `conversation/bgDoneNotice.ts`). Every row but a prompt made inside the bracket is the background
  turn's. A running or quiet one hides its replies (`backgroundTurns.ts` `hiddenInBackground`).

## Inventory

State: **fixed** (merged), **open** (root cause known), **unknown** (seen, not reproduced).

| ID | What the reader sees | Stage | State |
|---|---|---|---|
| T1 | A reply written in a background finish's turn never draws: "Used a tool and ran a command / Worked for 18s", then the next turn's words | 1 | fixed here |
| T2 | Every reply after a daemon restart is hidden: a background bracket that never closed owns all later rows | 1 | fixed (follow-up PR) |
| T3 | Under the Claude `runs` fold, a background turn's reply takes the prompt turn's answer slot, and the real answer folds away | 2 | fixed (follow-up PR) |
| T4 | A large gap between the last tool row and the live Thinking line | 3 or 4 | unknown |
| T5 | The settled reply flickers in from the left middle of the pane, then lands | 4 | unknown |
| T6 | A one-line acknowledgement of a background finish is hidden with nothing to open it from | 2 | open (taste) |
| T7 | Thought rows open on some clicks and not others | ? | unknown |
| T8 | The fork button shows only after later tool calls | ? | unknown |
| O-rows | No space before a new "Working for" row; folds firing mid-turn; text visible while folding; entrances replaying on scroll; the Thinking to tool-call swap; the spinner; bottom buttons missing after a stop | 3, 4 | `design/chat-animation-ordering-map.md` |

### T1. A reply in a background finish's turn never draws

- **Seen**: Leo, 2026-11-21 05:18Z, chat `claude-sr2-coord`. He sent a message with a screenshot.
  The pane drew his message, "Used a tool and ran a command", "Worked for 18s", no reply, then the
  next turn's first words. The agent had answered in five paragraphs.
- **Recorded order** (acpmux log, seq 1009805 to 1010120): a background command's finish opened the
  turn (`bg-done-…`, 05:18:19Z); his message came 15 s in as a steer; two calls; another agent's
  message steered in; the reply streamed (958 characters); `turn_result` `completed`; the other
  agent's message was carried to the next turn, whose reply drew.
- **Root cause**: `direct.ts` closed every successful finish's turn as quiet (`quiet: !failed`),
  whatever the agent wrote, and `settleReaction` skipped these turns. A quiet background turn hides
  its replies, and the default inline look has no line to open them from. The rule came with the
  finish's own line (#44710, 2026-11-17), which assumed the agent only acknowledges a finish. A
  coordinator's chat reports through these turns, and a person's steer lands in them.
- **Measured**: the recorded 9 minutes (05:15Z to 05:23Z) replayed through the pane's reducer and
  fold: 12 replies held, 8 drawn, 4 hidden (2,788 characters), all four in a finish's turn. After
  the fix: 12 drawn, 0 hidden.
- **Fix**: a finish's turn is quiet only when the task went well and the reply is an
  acknowledgement by acpmux's own rule (one line of at most 160 characters, no question, no link;
  `backgroundTurns.ts` `isQuietReply`, the rule of `background_turn.rs` `is_quiet`). A turn that
  said more draws its report under the task's line (`headsBackground`). The person's message into
  the turn ends the background turn there (`endBgDoneTurn`, reason `prompt`), so an answer to the
  person draws however short, and while it streams.
- **Test**: `webviews/test/background-finish-keeps-replies.test.ts` (the recorded order, a reply
  while the turn still runs, a one-word answer, a report with no steer, an acknowledgement stays
  hidden). Four of five fail on the base.
- **Not the cause**: the wrap-up tool. The turn made no `wrap_up` call, and text followed by a
  `wrap_up` call draws in every order tried (1,872 generated combinations of endings, openers and
  delays, by full replay and at every prefix).
- **Follow-up**: acpmux should write the bracket and `quiet` for these turns itself, as it does for
  Claude Code's own turns, so the pane decides nothing.

### T2. An unclosed background bracket hides every later reply

- **Repro** (generated, not yet seen in a recording): `background_turn started`, no `ended`, then a
  prompt's turn. The turn's reply is tagged to the bracket and hidden; its prompt and "Worked for"
  draw.
- **Root cause**: `OrderedRows.backgroundAt` (`direct.ts`) matches every later row once a span has
  no end. acpmux keeps running background turns in memory only, so a restart or a hot swap while
  Claude Code runs its own turn never writes the `ended` record.
- **Fix**: a prompt that opens a turn (a `user_message` that is no steer, or a `turn_started`
  with `carried`) ends every background turn still open before it (`promptEndsBackground`), as
  acpmux's own `ended` with reason `prompt` would have. And a reply acpmux stamped with a prompt's
  turn (its segment starts with the turn's id, "-" for the agent's own turn) is never a background
  turn's, whatever span its record falls in (`OrderedRows.promptsReply`); a record that splits
  such a reply no longer cuts it in two rows.
- **Test**: `conversation/finalReplyClass.test.ts` R1 to R3b, and its sweep of 1,872 orders.
- **Follow-up**: acpmux writes the `ended` record for a bracket left open when it starts.

### T3. A background reply takes the turn's answer slot (`claude-turn-fold: runs`)

- **Repro** (generated): a prompt's reply, then `background_turn started` and that turn's reply
  before the prompt's `turn_result`. acpmux can log this order: `finish_turn` clears the turn, then
  waits before it writes `turn_result`, and a task-notification turn that starts in the gap is
  bracketed inside the first turn's rows.
- **Root cause**: `answerAt` (`turns.ts`) reads the background reply as the turn's last reply, so
  the real answer is marked `foldedReply`. Only under the `runs` arm with the Claude family; the
  default arm draws both.
- **Fix**: `answerAt` skips rows another turn owns (`inBackground`) when the turn has a reply of
  its own.
- **Test**: `conversation/finalReplyClass.test.ts` R4.

### T4. A large gap between the last tool row and the Thinking line

- **Seen**: Leo, 2026-11-21. Not yet reproduced.
- **What should be there**: 16 px between a step row and the live line, whose box is 32 px
  (`transcriptGrid.ts` `transcriptGap`, `TRANSCRIPT_LIVE_STEP_BOX`); tool-line centre to live-line
  centre 43 px (`transcriptSpacing.ts`).
- **Candidates, by reading**: (1) the tool row placed at its estimate instead of its drawn height
  (`VirtualTranscript.tsx` `heightAt` falls back when the width, status edge or reply-actions flag
  differs; the estimate assumes open groups, up to 224 px more than a closed row draws); (2) a tail
  glide that started the live line low and was paused when the reader took the view
  (`tailGlide.hold`); (3) a height fold that never finished.
- **How to tell them apart**: per painted frame, the drawn gap (`getBoundingClientRect`) against
  the layout gap (`offsetTop`), and the live line's computed `translate`. A layout gap over 16 is
  (1); a drawn gap over the layout gap is (2) or (3).

### T5. The settled reply flickers in from the left middle

- **Seen**: Leo, 2026-11-21. Not yet reproduced.
- **Candidate, by reading**: at a turn's end, a reply that was not mounted before the fold
  (`turnEndFold.ts`, the `arrives` path) starts at the lowest kept row's slide distance, which is
  the height of the work that folds away, and rides it over 180 ms. Its own 80 ms fade ends first,
  so it reads as a full-ink row travelling from mid-pane. `turnEndFold.ts` is being changed in
  cmux#48554; a fix lands on top of that.
- **How to measure**: `webviews/test/agent-pane-turn-end-motion.test.ts` with the reply arriving in
  the same snapshot as the turn's end: the reply's first painted top against its final top.

### T6. A one-line acknowledgement is hidden with nothing to open

After T1, a finish's turn that said one short line still hides it, and the inline look draws no
line that opens (`collectFoldedBackgroundId`). That is the rule Leo set for turns with nothing to
tell ("a turn you didn't start that has nothing new to tell you shouldn't show up as a message or
ping you"), but the words are not reachable at all. Open question of taste, not a bug: whether the
task's line should open to them.

## Detectors

| Class | Detector |
|---|---|
| A reply held by the daemon and not drawn | `conversation/repliesDrawn.ts` (`undrawnReplies`), `conversation/finalReplyDrawn.test.ts` over two recordings and random chats. Gap: its oracle skips background finishes' turns, which is how T1 passed; T1's test covers them. |
| A reply drawn but never painted | `replyJudge.ts` (`reply-unpainted`), the last turn's final reply only |
| A gap that is not on the grid | `webviews/src/gallery/invariants.ts` (`gap-token`); layout only, blind to transforms |
| A row that jumps at a turn's end | `webviews/test/agent-pane-turn-end-motion.test.ts`, `turn-transition-jumps.test.ts` |
