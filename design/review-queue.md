# Waiting on you: every agent's open ask, ranked

The agent pane's History screen has a Waiting on you tab (`webviews/src/agent-session/acpmux/queue/`,
`QueueScreen.tsx`). It reads acpmux's `_acpmux/review_queue` and lists every ask that waits on
the person, ranked by acpmux's score. An ask can be:

- a tool approval
- a plan to approve
- a question
- a pull request ready for review

The asks come from every chat, on this Mac and on the person's other machines. The keyboard
moves through them and answers this Mac's approvals and pull requests without opening each chat.

## References

- A priority inbox: one ranked list, the selected row expanded, single-key triage, and an answered
  row that leaves in place.
- A review tool's keyboard: j/k to move and one key for each verdict.

## Layout

- One list, ranked by score (then the oldest ask, then id, so the order never shuffles between reads).
- Row line 1: the kind's glyph, the ask, and the age. Line 2: the chat's title, the host (when it is
  another machine), the agent, and why it ranks high (`impactReasons` in words: "Blocks a turn",
  "Prompts queued: 2", "Spent $3.40", "Sub-sessions: 3", "Waiting long").
- The selected row shows its answers (Allow / Deny, or a plan's own two options) with the app's
  shortcut on each, and its detail. A question shows "Answer in its chat": its card there asks the
  whole question. Other rows keep that slot reserved at height 0, so moving the cursor moves
  nothing else.
- Pull request rows show Accept and Request changes. Each sends its verdict at once; acpmux records no comment, so the row asks for none, and what should change is said in the chat.
- Under the list: the key hints, the machines that did not answer the read, and Export audit.
- There are no borders: the selected row is one tonal step up.

## Keys

| Key | Does |
| --- | --- |
| j / ↓, k / ↑ | move the cursor |
| Return | open the chat in this tab, as History's own rows and the sidebar do (`chat.select`; another machine's chat by its listed row) |
| Allow Once shortcut (⌥⌘1 by default) | allow once (a plan: approve; a pull request: accept) |
| Deny shortcut (⌥⌘3 by default) | deny once (a pull request: open Request changes) |
| x | export the audit trail (`_acpmux/audit`, every page) to the clipboard as JSON; a refused copy says it failed |

A chord (Cmd, Ctrl, Alt or Shift) is the app's, never the queue's. Answers take the app's
permission shortcuts, not plain letters: a permission answer needs the person's own click or that
shortcut, which the host counts as theirs (`AgentPaneUserGestures`, cx-ocdz), and never a keystroke
the page saw. The footer shows the shortcuts as the person has them bound.

## Answering

The page answers the same way Needs you does: `answerParams` builds the `chat.permission` params,
and `answerAnotherChat` (needsYou/useNeedsYou.ts) sends them through the host's
`chat.asks.answer`. There is no second path. A question is answered in its chat: no chat shows on
this page for `chat.permission`, and `chat.asks.answer` takes tool permissions only. An ask from
another machine is answered there and offers no answer here (the host cannot answer a peer's
permission, nor record a peer's verdict). A pull request verdict goes through
`_acpmux/review_verdict`.

## Row states

| State | Start | End |
| --- | --- | --- |
| Arrives after the first read | — | fades and grows in on the house curve |
| Answered | the row | stays drawn, collapses (`grid-template-rows` 1fr → 0fr) and is hidden from assistive tech; the cursor moves to the next row in the same frame. The next read drops it |
| Answer refused | collapsing | back in place with "Could not answer it here."; a refused Request changes brings its box back with the text typed |
| Another machine's ask | — | "Answer on {host}", no answers; Return opens its chat; the row stays until that machine answers |
| Older acpmux (`method not found`, or not on the relay's list) | — | "This Mac's agent service is older and keeps no queue yet. Update cmux to see every ask here." |
| Empty | — | "Nothing is waiting on you." |

## Variants (gallery `agent-pane.review-queue`) and the pick

1. `inbox`: two lines per row, with the answers only on the selected row.
2. `cards`: every row is a tonal card, with its answers and detail showing.
3. `compact`: one line per row, answered by the app's permission shortcuts only.

Shipped: `inbox`. It fits about 10 asks in a pane, and the reasons stay readable. Answers appear
exactly where the cursor is. `cards` fits 3 asks and makes the eye hunt across repeated buttons.
`compact` hides why an ask ranks high, and that reason is the point of the queue. The gallery
also covers 300 asks, an unreached machine, loading, empty and older.

## Host and cost

- The page is a tab of the History screen, with no new Swift view. It reads again when the
  pane's snapshot changes what the queue lists (debounced 400 ms): an ask on this Mac, a listed
  chat's ask count or waiting state, or its pull request, on any machine (`queueKey`). It also
  reads after an answer, never on a timer and never only because the person switched back.
  Stale replies are dropped.
- The relay allowlist lists these methods, with the params shown:
  - `_acpmux/review_queue`: `localOnly`, `limit`
  - `_acpmux/audit`: `since`, `until`, `sessionId`, `limit`, `cursor`
  - `_acpmux/review_verdict`: `prUrl`, `sessionId`, `verdict` (acpmux ignores a `comment`, so the page sends none)

  `_acpmux/review_verdict` requires a gesture, and it follows the source rule (`source_scoped`):
  for a chat outside the pane's scope it takes the click's scope credit, so a click spent attaching
  another chat cannot also send this one a verdict. None of the params carries a command.
- Rows are memoized, so moving the cursor redraws two rows. Rows past the viewport skip layout
  and paint (`content-visibility: auto`), so a frame costs the visible rows whatever the length of the queue.
