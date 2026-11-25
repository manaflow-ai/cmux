# Chat stream scenarios: what the agent pane does in every case

Leo, 2026-11-22 08:26Z: "there are probably more bullshit scenarios. we need to map them all out and note what
expected behaviours are for all. idek."

Every chat-pane bug on 2026-11-22 was found by Leo, by hand. One reply drew as two bubbles cut mid-bold with a
"Worked for 14s" fold between the halves (a pause read as a step boundary). A reply's paragraphs drew twice. Tool
calls grew and then collapsed at turn end. The pane faded in from the bottom, flashed, blanked. Icons came late.
The since-you-were-here marker called his latest message new. The caret lagged on paste. Received messages had a
gap of their own, and the status spot lost its shimmer.

This page is the map: each axis, its cases, what the pane must do in each, and who owns it. It is executable.
`webviews/src/agent-session/acpmux/sim/streamScenarios.ts` holds the same ids, and
`webviews/test/chat-stream-scenarios.test.ts` runs every `sim` and `live` case in CI on each webviews PR. The ids
here and there must match; the test fails when this table is missing an id.

## The invariants (every scenario, every step)

These come from Leo's words. Every scenario checks them unless its row names an exemption.

| # | Invariant | Leo | Checked by |
|---|---|---|---|
| I1 | **One message, one bubble.** A reply streamed as one message (one `messageId`) draws as one row. A pause, a stale summary, a reconnect or a daemon restart never splits it. Two bubbles happen only at a real boundary: a tool call, a thought, a steer, a permission or ask decision, a turn end. | 11-22 08:25 on 1158 | `i-split-bubble` |
| I2 | **Nothing is drawn twice.** A paragraph appears once per turn. A retried, replayed, duplicated or re-read record never adds text. | 11-22 08:02 on 1157 | `i-repeated-paragraph`, `i-text-conserved` |
| I3 | **Nothing is lost.** The text the agent sent equals the text the rows hold, after any delivery. | 11-06: "your intermediate message got lost. that can never happen" | `i-text-conserved`, delivery property test |
| I4 | **A fold only at a real boundary.** No row folds before its turn's `turn_result`. The one exception is a finished run of calls that closes under the agent's next paragraph (#48597). A row the reader opened stays open. | 11-21 05:48: "i thought we dont fold while you're still going"; 11-08: "if i have a tool call expanded, the auto folding situation shouldn't collapse it" | sim rule (b) |
| I5 | **Settled content.** Once its turn ends, a reply has every Markdown span closed and draws no placeholder or live row. | #49992 | `i-unclosed-markdown`, `i-placeholder-after-end` |
| I6 | **No layout shift.** Rows above the newest change keep their objects and positions. Only the running turn's tail moves. A fold leaves in one motion: the ink exits, then the rows move (design/chat-fold-motion.md). | 11-20: "it doesn't layout shift... we shouldnt either!"; 11-18: "calculate each beforehand everything that would move" | sim rules (a), (c); browser lane `b-mid-turn-shrink` |
| I7 | **Never blank.** Every load, reload, tab switch and reconnect draws the last known rows at once, in place. | 11-22 07:31: never hit the bug classes a reload would fix | elsewhere (VS-05, VS-08) |
| I8 | **One status voice.** The status spot shows one live line. Every label in it ("Thinking", "Waiting", "Sending", …) shimmers the same way, and any in-progress work counts as live. | 11-22 08:29 on 1160 | ST-03, ST-04 |

### Budgets

| What | Budget |
|---|---|
| A chunk to its pixels, scrolled to the bottom | the next frame (16 ms), no catch-up jump |
| Turn end to the settled frame: fold done, icons shown | one fold motion (design/chat-fold-motion.md timings); icons the same frame as `turn_result` |
| Reopen, tab switch, renderer restart to the first drawn frame | the retained snapshot's frame, no blank frame |
| Reconnect to the "reconnecting" line | none under 2 s; the line only past that |
| Paste to the caret at the end | the same frame as the attachment preview |
| Shaping cost per record at 10k+ rows | about the same as at 100 rows (chat-sim long run) |

## Ownership, today

| Owner | Area |
|---|---|
| helper `ae03a5b84e9c36fd5` (branch `fix/chat-duplicate-text`) | split and duplicate reply: I1, I2 |
| #49992 `inbox-row-gap` | start-record-late placeholder |
| helper, branch `lane/chat-received-as-activity` | received and sent-to rows as activity rows (ST-02) |
| helper, branch `lane/chat-status-shimmer` | shimmer for every status label (ST-03, ST-04) |
| #48663 `lane/chat-mid-turn-shrink` | false grow-then-collapse at turn end, the turn-end fold |
| #49963 `fix/turn-action-row-pop-in` | late Copy/Fork/Timeline icons |
| #49873 / #49876 / #49891 `lane/since-you-were-here-ui*` | since-you-were-here marker |
| #47553 `lane/chat-tab-switch-keeps-frame` | pane blanking, tab switch |
| gcp-agent-lane-4/ask-cdfac12eab, #45741 | layout shift on load, the layout watch |
| #49596 `lane/stream-follow-smooth` | stream follow while folding |
| #49439 composer typing lag | caret on paste |
| cmuxterm-hq#8950 | delivery faults that still diverge |
| chat-scenarios (this map) | everything else; failures with no owner are fixed in this map's PRs |

## The map

Status: **pass** or **fail** is the CI result of the sim case on the PR that added this page (counts in
"Results"); **elsewhere** means the named test holds it, since the model can't see pixels, motion, focus or input;
**known red** means it fails today and is routed to its owner.

### Stream events

| id | scenario | expected | owner | sim id | status |
|---|---|---|---|---|---|
| SE-01 | Text deltas, one reply | One bubble grows in place; rows above never move; text equals what was sent. | chat-scenarios | sim | see Results |
| SE-02 | Short pause (2 s) mid-reply | Same bubble resumes. No fold, no Worked for, no new row. The live line keeps "Working for". | ae03a5b8 | sim | see Results |
| SE-03 | Long pause (90 s) mid-reply, same message | Same bubble resumes after the pause. A pause is never a step boundary. No fold until `turn_result`. | ae03a5b8 | sim | see Results |
| SE-04 | Long pause inside `**bold**` (Leo's 1158 shape) | One bubble. The bold span closes in the same bubble. No Worked for between the halves. | ae03a5b8 | sim | see Results |
| SE-05 | Thinking, then the reply | The thought sits in the turn's activity, and the live line reads "Thinking", shimmering. The reply is one bubble under it. | chat-scenarios | sim | see Results |
| SE-06 | Tool call between two paragraphs | Paragraph, tool row, paragraph: a real boundary, so two bubbles are right. The run folds at turn end, or under the next paragraph (#48597). | chat-scenarios | sim | see Results |
| SE-07 | Tool call running for a minute | The call row stays live (shimmer, elapsed time). Nothing above moves. It settles in place when it ends. | chat-scenarios | sim | see Results |
| SE-08 | Nested subagent | One subagent row, live while it runs, with its own work inside it. The parent's reply stays one bubble. | chat-scenarios | sim | see Results |
| SE-09 | Permission card mid-turn | The card draws in the bottom stack, not in the transcript. Once answered, a one-line receipt row. The reply before it is whole. | chat-scenarios | sim | see Results |
| SE-10 | Ask card (AskUserQuestion) | The question draws as a card while open, then as one question-record row with the answer. No mid-turn fold. | chat-scenarios | sim | see Results |
| SE-11 | Turn end | The work folds into one Worked for line at `turn_result`, in one motion (exit before move). The final reply stays. No placeholder. Footer icons arrive the same frame. | #48663 | sim | see Results |
| SE-12 | False turn end: the summary says ended, then more chunks | A turn ends only on `turn_end`/`turn_result` for its id. A stale summary mid-stream never closes the bubble or draws Worked for. | ae03a5b8 | live | see Results |
| SE-13 | Turn fails (error) | The partial reply stays as written. One error row says why, with Retry. No placeholder. Nothing lost. Exempt from I5's Markdown check. | chat-scenarios | sim | see Results |
| SE-14 | Stop (cancel) mid-reply | The reply stops where it was, and the renderer closes any open span. A Stopped marker. No placeholder. Stop goes the same frame. Exempt from I5's Markdown check. | chat-scenarios | sim | see Results |
| SE-15 | Steer sent mid-reply | The words before the steer stay above it. The steer bubble reads Waiting, then read. The answer starts below it. No mid-turn fold. | chat-scenarios | sim | see Results |
| SE-16 | Steer sent during a tool call | The call stays live and in place. The steer waits under it. Nothing folds before `turn_result`. | chat-scenarios | sim | see Results |
| SE-17 | Queued message starts the next turn the moment one ends | The queued prompt leaves the composer queue and opens a new turn at the turn gap. The old turn folds once. No placeholder is left between. | chat-scenarios | sim | see Results |
| SE-18 | Hook re-prompt (Stop hook feedback) mid-turn | **[taste]** See "Taste calls". Pick: the hook's feedback draws as a quiet notice line between the two replies, so a repeated answer reads as a response to it, not a duplicate. | ae03a5b8 | sim | see Results |
| SE-19 | Background task ends after the turn; the agent wakes | A background turn draws under its own line. The earlier turn's fold does not reopen or move. | chat-scenarios | sim | see Results |
| SE-20 | Compaction mid-turn | One compaction line, live and then settled in place. Nothing above it moves. No fold before turn end. | chat-scenarios | sim | see Results |
| SE-21 | Model switch mid-chat | No transcript row moves. At most a one-line note at the boundary. | chat-scenarios | sim | see Results |
| SE-22 | Another agent's notice opens a turn | The notice line stands the block gap (24) under the last turn. Working for stands the head gap under it. | chat-scenarios | sim | see Results |
| SE-23 | Another agent's message opens a turn | As SE-22, for a message. | chat-scenarios | sim | see Results |
| SE-24 | Plan updates | One plan row, updated in place on each update. No new rows. | chat-scenarios | sim | see Results |
| SE-25 | Harness retry supersedes a message | The superseded text goes. The retried text draws once: never both, never a repeated paragraph. | ae03a5b8 | sim | see Results |
| SE-26 | start-record-late: the turn's start arrives after its end | An ended turn draws no placeholder rows, so no empty 16 px typing row under the footer (#49992, `carriedNoticePlaceholder.test.ts`). | #49992 | live | see Results |
| SE-27 | Host notice mid-reply | The notice line draws below the reply. The reply's later words stay in the same bubble above it. | chat-scenarios | sim | see Results |
| SE-28 | Long turn: rounds of text and calls with a long wait | Runs close only under the next paragraph or at turn end. Nothing else folds mid-turn. | chat-scenarios | sim | see Results |
| SE-29 | The person writes while a reply the agent started on its own (a background turn) is mid-sentence. Found by the integrity checker in Leo's own chat, session b0e9114e seq 5244663-5244700. | The rest of that message joins its bubble above the person's message: one message, one bubble, no span cut. The person's message and its answer follow it. | helper ae03 | sim | see Results |
| SE-30 | Steer after the turn's first text and before a send (Sent to) tool call, then more text. Leo 09:53Z: "the ordering here is really funky. i steered, you already had something you wanted to send/do, then you did another thing?" | Text written before the steer stays above it, then the steer, then the send and the reply, in that order. In Leo's capture the records came in that order: his prompt ended a quiet background turn, and the agent's first words ("Nothing has changed for you yet.") were what it had queued before reading him. | chat-scenarios | sim | pass |
| SE-31 | A Sent to row in a turn whose Worked for is closed. Leo 09:53Z: "it looks like there's \"extra\" spacing here" | A row the closed fold hides takes no space: no blank gap between the replies. Sent to folds into the turn's activity (ST-02) and shows with it. The replay of his chat (seq 5330115-5330880) is clean in the model, so this is a drawn-pixels bug. | received-rows helper (ST-02) | elsewhere | red (his capture) |
| SE-40 | Pause (5 s, then 20 s) inside `**bold**` and inside `` `code` `` | One bubble. Both spans close in it. No Worked for or fold between the halves. | ae03a5b8 | sim | green (this fix) |
| SE-41 | Pause inside `**bold**`, then the socket drops and reconnects | The reply resumes in the same bubble. The bold span closes in it. Nothing is drawn twice. | ae03a5b8 | live | green (this fix) |
| SE-42 | Pause inside `**bold**` in a background turn; it ends and a queued prompt starts mid-message (false turn end) | The rest of the message joins its bubble above the prompt (acpmux keeps one message's segment across the turn change). The span closes in it. | ae03a5b8 | sim | green (this fix) |
| SE-43 | Pause inside `**bold**`, then a background task's notification lands mid-message | The task's line draws below the reply. The rest stays in its bubble above it. | ae03a5b8 | sim | green (this fix) |
| SE-44 | A new subagent's first records land between two paragraphs of a reply (Leo's 1157) | The group draws. The reply stays one bubble with each paragraph once: a subagent is no step of the session's. | ae03a5b8 | sim | green (this fix) |

### Status spot and activity rows (Leo 08:29-08:30Z, must fix)

| id | scenario | expected | owner | sim id | status |
|---|---|---|---|---|---|
| ST-01 | start-record-late placeholder | An ended turn draws no placeholder rows. | #49992 | elsewhere: `carriedNoticePlaceholder.test.ts` | queued to merge |
| ST-02 | Received and Sent-to rows mid-turn (images/1159.png). Leo: "this one seems to have an unnecessary gap due to being a recieved message. these aren't categorized properly under our tool call formatting." | Received-message and sent-to rows are activity rows. They group and space exactly like tool calls (the 22 px rhythm, the same gap) and fold into the turn's activity, with no extra margin. | lane/chat-received-as-activity | elsewhere: sim `received-sent-as-activity` | fix in flight |
| ST-03 | In-progress activity has no shimmer (images/1160.png). Leo: "these situations, there's no glimmer because... well shit i dont know. you sending messages or whatever aren't being accounted properly a la the "thinking" thing." | Any in-progress activity counts as live work in the status spot and shimmers exactly like "Thinking". That covers sending a message, a helper's notification being handled, and waiting on a reply. | lane/chat-status-shimmer | elsewhere: status-label unit test and gallery | fix in flight |
| ST-04 | "Waiting" drawn white. Leo: "the "waiting" also shouldnt be special cased as white. all in the "thinking" spot should glimmer like that" | Every status in the thinking spot uses one shimmer style, with no white special case. | lane/chat-status-shimmer | elsewhere: status-label unit test and gallery | fix in flight |

### Markdown across chunk boundaries

Each case cuts the span between two chunks and stalls 20 s at the cut. Expected for all: **one bubble. While the
reply streams, an open span draws in its intended style (no raw `**` or fence flashes). Once settled, the span is
closed in the same bubble.**

| id | scenario | expected | owner | sim id | status |
|---|---|---|---|---|---|
| MD-01 | Bold split across chunks | As above. | ae03a5b8 | sim | see Results |
| MD-02 | Code fence split across chunks, with a pause | As above. The fence's box does not change height when it closes. | ae03a5b8 | sim | see Results |
| MD-03 | Table split across chunks | As above. A partial row draws as a row, never as a paragraph of pipes. | ae03a5b8 | sim | see Results |
| MD-04 | List split across chunks | As above. | ae03a5b8 | sim | see Results |
| MD-05 | Link split across chunks | As above. The link text draws plain until its URL closes, then becomes a link with no reflow. | ae03a5b8 | sim | see Results |
| MD-06 | Math split across chunks | As above. The source stays hidden until the math closes. | ae03a5b8 | sim | see Results |

### Transport

| id | scenario | expected | owner | sim id | status |
|---|---|---|---|---|---|
| TR-01 | Socket drops mid-reply and reconnects | The reply resumes in the same bubble from where it was. Nothing above redraws. The reconnect line shows only past its budget. | ae03a5b8 | live | see Results |
| TR-02 | A chunk delivered twice | The duplicate is dropped, and the text draws once. | cmuxterm-hq#8950 | live | see Results |
| TR-03 | Two chunks out of order | Once the late chunk arrives, the text is in order, in one bubble, with nothing lost. | cmuxterm-hq#8950 | live | see Results |
| TR-04 | A chunk arrives after `turn_result` (late) | The chunk takes its place in its reply, and the turn is repaired. One bubble. No new turn, and no fold reopens. | cmuxterm-hq#8950 | live | see Results |
| TR-05 | Daemon restart mid-reply (segment numbering restarts) | The same message (same `messageId`) stays one bubble across the restart. The turn is adopted, not ended. No Worked for between the halves. | ae03a5b8 | live | see Results |
| TR-06 | Session resume: close the pane and open it again | The reopened chat draws the same rows, in place, at once. Never blank, and no fold motion replays. | #47553 | live | see Results |
| TR-07 | Replay equals live; lost frames are read back at turn end | Any delivery (lost, swapped, duplicated, dropped) converges to the in-order rows once the turn ends. | cmuxterm-hq#8950 | elsewhere: `transcript-delivery-property.test.ts` | known red (#8950) |
| TR-08 | Fork | The fork opens on the kept tail, drawn at once. The source chat does not move. | chat-scenarios | elsewhere: `agent-pane-fork-kept-tail.test.ts` | elsewhere |

### View state

| id | scenario | expected | owner | sim id | status |
|---|---|---|---|---|---|
| VS-01 | Unfocused, then refocused (since you were here) | The marker sits at the first record the reader had not seen when they left. The reader's own latest message is never "new". No layout shift when the marker appears or fades. | since-you-were-here PRs | elsewhere: `agent-pane-since-jump-tab-row.test.ts` | routed |
| VS-02 | Scrolled to the bottom while streaming | The view follows smoothly, with no jolts. Folds above do not move the bottom. | #49596 | elsewhere: browser lane `b-mid-turn-shrink` | routed |
| VS-03 | Scrolled up while a turn runs and ends | What the reader looks at does not move: it is anchored by (rowId, offset), and folds below the viewport are held. | chat-scenarios | sim (`reader-scroll`) | see Results |
| VS-04 | Pane resize | Rows reflow, and the anchored row keeps its offset. No flash. | #45741 | elsewhere: layout watch | routed |
| VS-05 | Tab switch, unloaded tab, tab moved to another pane | The pane keeps its frame. No re-render flash, and the original pane does not flicker. | #47553 | elsewhere | routed |
| VS-06 | Window hidden, then shown | On show, the settled state draws at once. No queued animation replays (no fade-in from the bottom). | #48663 | elsewhere: chat-fold-motion.md | routed |
| VS-07 | Theme change | Only colours change; no row moves. | #45741 | elsewhere: theme gallery | elsewhere |
| VS-08 | Renderer restart or reload | Never blank: the retained snapshot draws in place at once, then live records continue. | #47553 | elsewhere: `agent-pane-restore-long-turn.test.ts` | routed |
| VS-09 | Huge history (10k+ rows) | Each step costs about the same at any length. Nothing folds early. | chat-scenarios | elsewhere: `chat-sim.test.ts` long run | pass |
| VS-10 | Images and attachments | Drawn at their stored size from the first frame, with no reshape when they load. | #45741 | elsewhere: hq handbook media-without-stored-size | elsewhere |
| VS-11 | Paste into the composer | The caret is at the end of the pasted text in the same frame as the attachment preview. | #49439 | elsewhere | routed |
| VS-12 | Pane loads (open, restart, update) | No flash, and no expand-then-collapse of tool calls: the first frame is the settled one. | #45741 | elsewhere: #49964 | routed |
| VS-13 | Turn finishes: action icons and the final reply | Copy/Fork/Timeline appear the frame the turn ends. The reply does not fade in from the bottom. | #49963 | elsewhere | routed |

### Timing: every event at every moment

`TM-<event>@<moment>` crosses 7 events with 6 moments in a turn, 42 cases, all generated by `timingCase` in
`streamScenarios.ts`.

- **Events:** steer, another agent's message, permission card, background task end, compaction, a 90 s pause, a
  tool call.
- **Moments:** before the first chunk, inside `**bold**`, between paragraphs, during a tool call, after a tool call,
  after turn end.

Expected for every one: all of I1-I6. In particular, a real boundary (steer, permission decision, compaction, tool
call) inside `**bold**` may split the bubble, and then each half's span must still read as intended. A pause or a
background end inside bold must not split it.

## Taste calls

1. **SE-18: a Stop hook's re-prompt.** Leo, 11-22 08:02: "i assume you got re-prompted here. i thought we removed
   those. you also basically said the same thing, so there didnt seem to be a point to that. if you did get hooked,
   i think it should get displayed better." Options:
   - (a) A quiet notice line, "Stop hook: <first sentence>", between the two replies, opening to the full feedback.
     This is how automated notices already draw (agentNotice.ts `AUTOMATED_NOTICE_HEADS` sender `hook`).
   - (b) Fold the reply that came before the hook into the turn's activity, so only the answer after the hook
     shows.
   - (c) Hide the hook and draw the two replies as one bubble.

   **Pick: (a).** It keeps every word (Leo, 11-03: "there are cases (rare) that you would want to see it") and
   explains the repeat. (c) would break I2.
2. **SE-14: a reply stopped inside a span.** (a) The renderer closes the span when it draws (bold stays bold up to
   the cut). (b) Draw the raw marks. **Pick: (a).** A stopped reply is settled content.
3. **Bottom space when scrolled up** (Leo 11-20 22:28, "debatable"). (a) Keep trimming the trailing space as rows
   arrive. (b) Leave it until the reader scrolls back to the bottom, as Claude Code and Codex do. **Pick: (b).** It
   moves nothing under the reader. Owner: #49596.

## Detectors (the meta-problem)

There was no scenario map, so every bug was found by Leo. Three detectors replace him:

1. **The scenario suite on every webviews PR.** `webviews/test/chat-stream-scenarios.test.ts` runs every `sim` and
   `live` case above in ci-web's webviews shard. A scenario that fails and has an owner is listed in `KNOWN_RED`
   with that owner. Its test asserts it is still red, so the fix that turns it green has to take it off the list.
   A new red anywhere else fails the PR.
2. **The bubble-integrity checker on real transcripts.**
   `bun scripts/chat-sim.ts --replay ~/.acpmux/sessions/<id> --integrity` runs the integrity rules on a recorded
   chat at every turn end. It checks for a split bubble (two rows of one message, or the first cut inside an open
   span, with a fold between), a repeated paragraph, an unclosed span in a settled reply, a placeholder after turn
   end, and text that is not conserved. It runs on Leo's NIGHTLY sessions and on cmuxterm-hq `fixtures/chat-sim/`.
   Its findings go to gcp-agent-lane-2/transcript-oddities.
3. **The existing sim rules** (sim/README.md): gaps (a), folds (b), stillness (c), and in Chrome the drawn boxes.
4. **The integrity rules in every sim run.** `runSimulation` (sim/run.ts) checks the integrity rules on each
   turn's rows at its `turn_result` and at the run's last step, as violations `i-*`, so
   `bun scripts/chat-sim.ts <scenario>` exits 1 on a split bubble, a repeated paragraph or a settled reply left
   open inside `**`, a fence, `$$` or an inline backtick. It reads only the ended turn's rows, so a long run pays
   per turn.

Rule of the map: a chat-pane bug Leo reports gets a scenario id here before its fix lands, and the fix's PR turns
that id green.

## Results

Filled in by the PR that added this page. See its body for the CI run, the pass/fail count, and where each failure
was routed.
