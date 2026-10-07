# conversation-sim wire protocol

A long-running fake remote conversation service. The cmux GUI conversation
surface connects to it in DEBUG builds to exercise the transcript under real
network pressure: latency, jitter, failures, duplicate delivery, disconnects,
and deep paginated history. The protocol mirrors the concepts acpmux exposes
(per-conversation monotonic `seq`, `beforeSeq` paging, `clientMessageId`
dedupe/echo, replay after reconnect, a lagged signal), so the client adapter
seam is the same shape as the real backend.

Transport: WebSocket at `ws://<host>:<port>/ws?conversation=<id>`, one JSON-RPC
2.0 object per text frame. Media over plain HTTP on the same port.

Conversations hosted: `group` (title "cmux", 3 other participants, ~20k
messages) and `direct` (1:1, ~5k messages). Both live for the life of the
process and keep growing.

## Requests (client to server)

| method | params | result |
| --- | --- | --- |
| `hello` | `{clientId, resumeAfterEventSeq?}` | `{conversation, me: Participant, headSeq, headEventSeq, serverTime, lagged}` |
| `history` | `{beforeSeq: Int?, limit: Int}` | `{messages: [Message], hasMore: Bool}` |
| `send` | `{clientMessageId, text, replyToId?, attachmentIds?}` | `{message: Message}` |
| `react` | `{messageId, reaction: Reaction?}` | `{message: Message}` |
| `edit` | `{messageId, text}` | `{message: Message}` |
| `typing` | `{isTyping: Bool}` | `{}` |
| `markRead` | `{upToSeq: Int}` | `{}` |
| `scheduleSend` | `{clientMessageId, text, replyToId?, attachmentIds?, scheduledAt}` | `{scheduled: Scheduled}` |
| `scheduled` | `{}` | `{scheduled: [Scheduled]}` |
| `reschedule` | `{id, scheduledAt}` | `{scheduled: Scheduled}` |
| `cancelScheduled` | `{id}` | `{}` |
| `sendScheduledNow` | `{id}` | `{message: Message}` |

`history` with `beforeSeq: null` returns the newest page. Messages are sorted
ascending by `seq`. `send` is idempotent on `clientMessageId`: a retry returns
the original message.

### Send Later (scheduled messages)

Scheduled messages live outside the message log: they carry no `seq`, never
appear in `history`, and are listed by `scheduled` (ascending `scheduledAt`,
then `createdAt`). `scheduledAt` is epoch ms, later than now (5 s grace) and at
most 14 days ahead; otherwise `-32602`. `scheduleSend` is idempotent on
`clientMessageId` while the message is scheduled, and fails with `-32602
"already sent"` once it has fired. `reschedule` (Edit Time, or Try Again on a
failed one) sets a new time and returns the state to `scheduled`.
`scheduleSend`, `reschedule` and `cancelScheduled` fail with `-32002 "not
delivered"` at `failRate` without changing anything.

When a scheduled message is due (checked every 250 ms) or `sendScheduledNow`
is called, the server creates a normal message with the same
`clientMessageId` (`message.created`, then delivery updates and bot reactions
as for `send`), then emits `scheduled.removed` with `reason: "sent"` and the
new `messageId`. At `scheduledFailRate` a due message instead becomes `state:
"failed"` (`scheduled.upserted`) and stays listed until it is rescheduled,
sent now, or cancelled. `sendScheduledNow` works on failed messages too.

When `resumeAfterEventSeq` is given, the server replays every event after it
as `event` notifications, in order, then sends `replayDone`. If the gap exceeds
500 events it sends nothing and returns `lagged: true`; the client must refetch
the newest page and rebase.

## Notifications (server to client)

`event` with params `{eventSeq, kind, ...}`:

- `message.created {message}`
- `message.updated {message}` (edit, reaction, delivery status, reply count)
- `scheduled.upserted {scheduled}` (scheduled, rescheduled, failed)
- `scheduled.removed {id, clientMessageId, reason: "cancelled"|"sent", messageId?}`
  (`messageId` only when sent)

`typing {participantId, isTyping}` is ephemeral and carries no `eventSeq`.
`replayDone {}` ends a resume replay.

Event delivery is ordered per connection. Duplicates are possible; the client
dedupes on `eventSeq` and on message `id`.

## Types

```
Conversation { id, title, kind: "group"|"direct", participants: [Participant] }
Participant  { id, name, initials, colorHex, isMe }
Message {
  id, seq, clientMessageId?, senderId, sentAt (epoch ms), text,
  replyToId?, replyCount, editedAt?,
  reactions: [{participantId, reaction}],
  attachments: [{id, kind: "image", width, height, url}],
  status?: "sent"|"delivered"|"read", readAt?    // only on my messages
}
Scheduled {
  id ("sched_<conversation>_<n>"), clientMessageId, senderId, createdAt (epoch ms),
  scheduledAt (epoch ms), text, replyToId?,
  attachments: [{id, kind: "image", width, height, url}],
  state: "scheduled"|"failed", error?
}
Reaction = "heart"|"thumbsup"|"thumbsdown"|"haha"|"exclamation"|"question"
```

## HTTP

- `GET /media/<id>.png`: procedurally generated image, served after a latency
  delay.
- `POST /upload` with raw image bytes and `Content-Type`: returns
  `{attachment}` usable in `send.attachmentIds`.
- `GET /healthz`: `ok`.
- `POST /admin/burst?conversation=<id>&count=<n>`: make participants send `n`
  messages rapidly (pressure testing).
- `POST /admin/disconnect`: drop every socket (reconnect testing).
- `POST /admin/knobs` JSON `{latencyScale, failRate, historyFailRate,
  duplicateRate, disconnectEverySeconds, botIntervalScale, scheduledFailRate}`.
- `POST /admin/scheduled/fire?conversation=<id>&id=<scheduledId>`: make one
  scheduled message due now (honors `scheduledFailRate`).
- `GET /admin/state` includes a per-conversation `scheduled` count.

## Simulated traffic

- `history`: lognormal delay, median ~1.1 s, clamped 0.4 to 4 s, times
  `latencyScale`; fails with JSON-RPC error `-32001 "upstream timeout"` at
  `historyFailRate` (default 0.07).
- `send`: ack after 120 to 900 ms; fails with `-32002 "not delivered"` at
  `failRate` (default 0.04). On `direct`, my message becomes `delivered` 0.3 to
  1.2 s after ack and `read` 2 to 10 s later. On `group`, `delivered` only.
- Every notification is delayed 15 to 350 ms (ordered), and duplicated at
  `duplicateRate` (default 0.02).
- Every socket is dropped at a random time every `disconnectEverySeconds`
  (default 240, jittered).
- Bots: a participant starts typing every 5 to 25 s, types for a time based on
  message length (sometimes stops without sending), then sends. Occasional
  bursts of 3 to 6 quick messages. Replies to my messages within 3 to 12 s
  most of the time, tapbacks my messages ~30% of the time, edits its own last
  message ~5% of the time.
