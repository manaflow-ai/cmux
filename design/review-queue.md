# Waiting on you: every agent's open ask, ranked

The agent pane's History screen has a Waiting on you tab (`webviews/src/agent-session/acpmux/queue/`,
`QueueScreen.tsx`). It reads acpmux's `_acpmux/review_queue` and lists every ask that waits on
the person, ranked by acpmux's score. An ask can be:

- a tool approval
- a plan to approve
- a question
- a pull request ready for review

The asks come from every chat, on this Mac and on the person's other machines. The keyboard
answers them without opening each chat.

## References

- A priority inbox: one ranked list, the selected row expanded, single-key triage, and an answered
  row that leaves in place.
- A review tool's keyboard: j/k to move, one letter for each verdict, and numbers for choices.

## Layout

- One list, ranked by score (then the oldest ask, then id, so the order never shuffles between reads).
- Row line 1: the kind's glyph, the ask, and the age. Line 2: the chat's title, the host (when it is
  another machine), the agent, and why it ranks high (`impactReasons` in words: "Blocks a turn",
  "Prompts queued: 2", "Spent $3.40", "Sub-sessions: 3", "Waiting long").
- The selected row shows its answers (Allow / Deny, a plan's own two options, or a question's
  numbered choices, at most 9) and its detail. Other rows keep that slot reserved at height 0, so
  moving the cursor moves nothing else.
- Pull request rows show Accept and Request changes. Request changes opens a comment box in the row.
- Under the list: the key hints, the machines that did not answer the read, and Export audit.
- There are no borders: the selected row is one tonal step up.

## Keys

| Key | Does |
| --- | --- |
| j / ↓, k / ↑ | move the cursor |
| Return | open the chat |
| a | allow once (a plan: approve; a pull request: accept) |
| d | deny once (a pull request: open Request changes) |
| 1–9 | pick a question's choice |
| x | export the audit trail (`_acpmux/audit`, every page) to the clipboard as JSON |

A chord (Cmd, Ctrl, Alt or Shift) is the app's, never the queue's.

## Answering

The page answers the same way Needs you does: `answerParams` builds the `chat.permission` params,
and `answerAnotherChat` (needsYou/useNeedsYou.ts) sends them through the host's
`chat.asks.answer`. There is no second path. An ask from another machine opens its chat instead
(the host cannot answer a peer's permission from here). A pull request verdict goes through
`_acpmux/review_verdict`.

## Row states

| State | Start | End |
| --- | --- | --- |
| Arrives after the first read | — | fades and grows in on the house curve |
| Answered | the row | stays drawn, collapses (`grid-template-rows` 1fr → 0fr) and is hidden from assistive tech; the cursor moves to the next row in the same frame. The next read drops it |
| Answer refused | collapsing | back in place with "Could not answer it here." |
| Peer ask answered | — | "Answer on {host}": its chat opens; the row stays until the peer answers |
| Older acpmux (`method not found`, or not on the relay's list) | — | "This Mac's agent service is older and keeps no queue yet. Update cmux to see every ask here." |
| Empty | — | "Nothing is waiting on you." |

## Variants (gallery `agent-pane.waiting-on-you`) and the pick

1. `inbox`: two lines per row, with the answers only on the selected row.
2. `cards`: every row is a tonal card, with its answers and detail showing.
3. `compact`: one line per row, answered by key only.

Shipped: `inbox`. It fits about 10 asks in a pane, and the reasons stay readable. Answers appear
exactly where the cursor is. `cards` fits 3 asks and makes the eye hunt across repeated buttons.
`compact` hides why an ask ranks high, and that reason is the point of the queue. The gallery
also covers 300 asks, an unreached machine, loading, empty and older.

## Host and cost

- The page is a tab of the History screen, with no new Swift view. It reads again when an ask
  comes or goes in the pane's snapshot (debounced 400 ms) and after an answer, never on a
  timer and never only because the person switched back.
  Stale replies are dropped.
- The relay allowlist lists these methods, with the params shown:
  - `_acpmux/review_queue`: `localOnly`, `limit`
  - `_acpmux/audit`: `since`, `until`, `sessionId`, `limit`, `cursor`
  - `_acpmux/review_verdict`: `prUrl`, `sessionId`, `verdict`, `comment`

  `_acpmux/review_verdict` requires a gesture. None of the params carries a command.
- Rows are memoized, so moving the cursor redraws two rows. Rows past the viewport skip layout
  and paint (`content-visibility: auto`), so a frame costs the visible rows whatever the length of the queue.
