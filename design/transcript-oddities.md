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
| T4 | A large gap between the last tool row and the live Thinking line | 3 | fixed (cmux#48701, cmux#48597) |
| T5 | The settled reply flickers in from the left middle of the pane, then lands | 4 | fixed (cmux#48689, follow-ups cmux#48904) |
| T6 | A one-line acknowledgement of a background finish is hidden with nothing to open it from | 2 | left as it is (taste, answered 2026-11-21) |
| T7 | Thought rows open on some clicks and not others | 4 | fixed (cmux#48711) |
| T8 | The fork button shows only after later tool calls | none (the turn's menu) | fixed (cmux#48711) |
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

- **Seen**: Leo, 2026-11-21: "see the space/gap between tool calls and the current shimmer? this
  isn't great."
- **Cause, in two parts**. (1) Most of what his screenshot shows was the designed room, not a
  fault: a 16 px gap above a live line drawn in a 32 px slot put the tool line's centre 43 px from
  the live line's, against 22 px between two step rows. (2) One case was a fault: after a steer
  with no step yet, the live line sat 32 px below it where the grid says 24, because the turn's
  mark row and the gap row both counted (`model.ts`).
- **Ruled out, by measuring**: a tool row placed at its estimate (the layout gap matched the drawn
  gap in every frame recorded), a paused tail glide, and a fold that never finished.
- **Fix**: the room is now 8 px above a 22 px box, 30 px centre to centre (`transcriptGrid.ts`
  `transcriptGap`, `LIVE_GAP_LOOKS`; picked from a sheet of four variants; cmux#48701). The
  32-vs-24 case is fixed in cmux#48597. Both belong to the row spacing work, see
  `design/chat-animation-ordering-map.md`.
- **Test**: `transcriptSpacing.ts` (the pitch table) and the steer-then-Thinking cases added with
  cmux#48597.

### T5. The settled reply flickers in from the left middle

- **Seen**: Leo, 2026-11-21: "your next settled message seemed to flicker in from the left middle
  of the pane for a breif moment, and then settle."
- **Cause**: at a turn's end the fold (`turnEndFold.ts` `playTurnEnd`, the `arrives` path) carried
  a row first mounted in the settle snapshot by the lowest kept row's fold offset, which is the
  height of the work folding away. A reply that only exists from that snapshot (a streaming reply
  renamed at settle, a reply outside the warm window, a row that arrives with the next turn) was
  painted 220 to 1200 px from its place for up to 55 frames. Its 80 ms fade ends before the 180 ms
  ride does, so it reads as a full-ink row travelling in from mid-pane.
- **Fix** (cmux#48689): such a row is laid out at its final top already, so it stays there, and it
  fades in once no kept row still slides through its box. Dropping the carry alone brings back
  the overlap of 2026-11-18 ("doubled up" text: 31 to 42 frames, up to 34 px); holding the fade to
  the move's end costs 232 ms to first ink in every case.
- **Numbers** (13 scenarios, every painted frame, headless Chromium): frames away from place 55 to
  0, overlap frames 0, first ink 52 ms in 11 scenarios and 224 to 232 ms in the 2 where a kept row
  slides through the reply's box.
- **Follow-ups** (cmux#48904, from the review of cmux#48689). (1) The hold was read once: a
  placement pass later in the fold (a row above measured shorter, the view scrolled) could send a
  kept row through the reply's box while the reply kept its first, zero-delay fade, visible over up
  to 34 px of that row. The hold is now read on every pass (`Moving.hold`), and the reply goes back
  to no ink until the row has passed. (2) The fold's backstop ended every animation 50 ms after the
  move, so a fade held to near the move's end was cut at about 28% ink and jumped to full. The
  backstop now waits for the latest held fade's end. (3) A row with its own entrance that nothing
  crosses gets no fade from the fold: its entrance is its only one.
- **Test**: `webviews/test/reply-settle-frames-real-browser.test.ts` (real Chromium, every painted
  frame: a relayout mid-fold, the backstop, a row with its own entrance);
  `webviews/test/reply-settle-place-browser.test.ts` (13 scenarios on a mocked clock); O7, O8 and
  O8b in `chat-order-O7-O14.test.ts`.

### T6. A one-line acknowledgement is hidden with nothing to open

After T1, a finish's turn that said one short line still hides it, and the inline look draws no
line that opens (`collectFoldedBackgroundId`). That is the rule Leo set for turns with nothing to
tell ("a turn you didn't start that has nothing new to tell you shouldn't show up as a message or
ping you"), but the words are not reachable at all. Open question of taste, not a bug: whether the
task's line should open to them.

Answered 2026-11-21 by Leo's proxy (shadow-leo, ask-ed692d3eb3), from that same rule: "Don't build
the clickable line today, and leave it unreachable as it is." Nothing was built. The question stays
open for Leo himself: should a finish's one-line acknowledgement be reachable from the task's line?

### T7. Thought rows open on some clicks and not others

- **Seen**: Leo, 2026-11-21: "inconsistent clicks (thought)".
- **Cause**: a folded Thought's button was as wide as its words (`.cv-thought.is-toggle`,
  `width: fit-content`), not its row: 136 px of an 800 px row. A click on the words opened it; a
  click on the empty line after them hit nothing. Tool and command rows take a click anywhere along
  the line, so the same gesture worked on one row and not on the next.
- **Ruled out**: text selection swallowing the click (the button is `user-select: none`; no
  selection swallowed one in the gesture table).
- **Fix** (cmux#48711): the button spans the row. The words still light only when the pointer is
  on the glyph, the words or the chevron (the 2026-11-06 rule: a thought opened under the pointer
  must not stay lit once the pointer leaves its words).
- **Test**: `webviews/test/thought-click-targets-browser.test.ts`: a click sweep along five thought
  shapes (32 clicks, 0 swallowed), a gesture table against the tool rows, and the hover colours on
  and past the words.

### T8. The fork button shows only after later tool calls

- **Seen**: Leo, 2026-11-21: "inconsistent forking button appearing that is somehow dependent on
  future tool alls?"
- **Cause**: the Fork under a finished turn and under a prompt was gated on the whole chat being
  idle (`messageMenu.ts` `canFork`: `!isWorking`). Every earlier turn's Fork vanished whenever a
  later turn ran, including turns the reader did not start (another agent's message, a background
  command's finish), and came back when that turn's last tool call ended.
- **Fix** (cmux#48711): `canForkTurn` keeps the per-turn Fork while a later turn runs for agents
  that can fork through any finished turn (`forksAnyTurn`: Claude and Codex). Other agents fork
  only at a chat's end and still wait for the idle chat. The app-level Fork Conversation is
  unchanged.
- **Follow-up** (cmux#48904, from the review of cmux#48711): with the Fork kept while a turn
  streams, the map of each prompt's turn was rebuilt from the whole chat on every streamed render
  (`promptTurns` then `editableKey`). `trackPromptTurns` now reads only the rows after the first that
  changed and keeps the same Map until an answered prompt changes
  (`webviews/test/edit-turns-tracking.test.ts`: one row read per streamed row in a 400-turn chat).
- **Test**: `conversation/forkTurnWhileWorking.test.ts`.
- **Not proven**: a live fork made while a later turn runs. That the daemon accepts it is from
  reading the path (`chat.fork` to the fork-through), not from a run in the app. The run is written
  out, step by step, in `design/transcript-oddities-readback.md` (R6).

## Detectors

| Class | Detector |
|---|---|
| A reply held by the daemon and not drawn | `conversation/repliesDrawn.ts` (`undrawnReplies`), `conversation/finalReplyDrawn.test.ts` over two recordings and random chats. Gap: its oracle skips background finishes' turns, which is how T1 passed; T1's test covers them. |
| A reply drawn but never painted | `replyJudge.ts` (`reply-unpainted`), the last turn's final reply only |
| A gap that is not on the grid | `webviews/src/gallery/invariants.ts` (`gap-token`); layout only, blind to transforms |
| A row that jumps at a turn's end | `webviews/test/agent-pane-turn-end-motion.test.ts`, `turn-transition-jumps.test.ts` |
| A row drawn away from its place as it arrives, or over a row still moving | `webviews/test/reply-settle-place-browser.test.ts` |
| A click on a row's line that does nothing | `webviews/test/thought-click-targets-browser.test.ts` |
| A per-turn action that depends on a later turn's state | `conversation/forkTurnWhileWorking.test.ts` (Fork only) |
