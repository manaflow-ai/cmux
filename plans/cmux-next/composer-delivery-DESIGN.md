# Composer delivery: never block on a slow send

Status: design, 2026-10-20. Follows #22732 (a prompt sent mid-turn left Return and Send dead).

## Problem

The agent pane's composer holds a sent prompt until acpmux says it took it. While it holds one,
Return and Send refuse a second prompt. On a slow link (a remote machine, a relay, a lagged event
stream) the person sees a full composer that will not send. #22732 shortened the hold. This design
removes it.

## Rule

Return sends at once, every time there is something to send. The prompt leaves the composer in the
frame of the press and shows as its own row (a bubble, or a queue row behind a running turn). The
row carries the prompt's delivery state. The composer is free for the next prompt at once. Send
never turns into a spinner and is never disabled because a prompt is in flight.

## States (per prompt, keyed by its client prompt id)

| State | Entered when | Row shows |
| --- | --- | --- |
| `sending` | the pane wrote `session/prompt` | a small clock beside the bubble, after 1 s only (a fast send shows nothing) |
| `delivered` | acpmux recorded it: `_acpmux/prompt_accepted`, a `queued` or `user_message` record, or the `session/prompt` answer | the bubble's check, unread |
| `read` | the agent started on it: its `user_message` record (a queued prompt dequeued) or a steer's `steered` | the bubble's check, read (UserBubble.tsx, owned by the message-actions lane) |
| `failed` | a refusal, or the timeout below | the reason, and Retry, Edit, Remove, Details |

A state only moves forward. A late signal for an earlier state is ignored.

## Hops and Details

Each send records timestamps per hop, so a failure names where it stopped:

1. app → acpmux: the request left the pane (`sentAt`); a `transport.*` error or a closed socket
   fails here.
2. acpmux recorded it (`acceptedAt`, `prompt_accepted`); acpmux refusals (`trust.pending`,
   remote guard, sandbox, gesture) fail here with acpmux's reason.
3. host → agent: the agent took it (`readAt`, `user_message`/`steered`); an agent error on the
   prompt's turn fails here.

Details opens under the row: the hop it stopped at, the error text and code, the latency of each hop,
the timestamps, the session id, the prompt id and the connection (local or the peer's name).
"Copy debug info" copies the same as plain text.

## Timeout

- A send with no acceptance after 10 s stays `sending`, and its row says "Still sending".
- After 60 s with no acceptance, or when the connection closes, it becomes `failed` ("No answer
  from acpmux"). Retry is safe (below).

## Reconnect and duplicate protection

The client prompt id is the delivery key. acpmux runs a prompt id once: the same id again answers
with the first run's outcome, marked `_meta.acpmux.duplicate` (`hub/turns.rs prompt_with`), and
`_meta.acpmux.resend` also looks in the session's log, which outlives a daemon restart.

- After a reconnect, every prompt still `sending` on that chat is sent again with the same id and
  `resend: true`. If the first copy landed, acpmux answers `duplicate` and the row moves to
  `delivered`; otherwise this is the first delivery. Never a second turn.
- Retry on a failed row sends the same id with `resend: true`. Edit then send is a new prompt
  (a new id), and the failed row goes.

## Recovery on a failed row

- Retry: the same prompt id again (above).
- Edit: the text and attachments go back into the composer (ahead of a draft typed since,
  never over it), and the row goes. A queued prompt uses `_acpmux/queue_edit` as today.
- Remove: the row goes; a prompt acpmux queued is withdrawn (`_acpmux/queue_remove`).
- Folder trust: the row says the folder is not trusted yet, with Trust. Trust re-sends this row's
  prompt, never whatever is in the composer (fixes the #22732 review's trust re-send case).

## Things that change elsewhere

- The workspace context rides with the first prompt and is spent only on a real acceptance, so a
  refused first prompt's Retry still carries it.
- Delivery state lives in the chat's own state, keyed by session id: a refusal that comes after
  the person switched chats lands as that chat's failed row instead of being dropped.
- The composer's `sending` hold and its "Still sending your last message" note go away.

## Tests

- Return twice while the first send has no answer: both prompts show as rows, in order, and the
  composer is empty.
- No acceptance: the row says "Still sending" after 10 s and fails after 60 s (an injected clock).
- Reconnect with a `sending` prompt: it is sent again with the same id and `resend`; a `duplicate`
  answer makes it `delivered` and starts no second turn.
- Retry, Edit, Remove and Trust on a failed row, and Details' hop for each refusal kind.
- A refusal after a chat switch shows in that chat when it is shown again.
