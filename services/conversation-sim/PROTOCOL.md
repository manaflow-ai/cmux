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
messages), `direct` (1:1, ~5k messages) and `empty` (1:1 with Kate Bell, no
messages: the empty-conversation and top-of-history state; no bot traffic
until I write). All live for the life of the process and keep growing.

## Requests (client to server)

| method | params | result |
| --- | --- | --- |
| `hello` | `{clientId, resumeAfterEventSeq?}` | `{conversation, me: Participant, headSeq, headEventSeq, serverTime, lagged, lastReadSeq, unreadCount}` |
| `history` | `{beforeSeq: Int?, limit: Int}` | `{messages: [Message], hasMore: Bool}` |
| `send` | `{clientMessageId, text, replyToId?, attachmentIds?, mentions?: [Mention], textRuns?, effect?: Effect}` | `{message: Message}` |
| `react` | `{messageId, reaction: Reaction?}` | `{message: Message}` |
| `edit` | `{messageId, text, textRuns?}` | `{message: Message}` (at most 5 edits per message; then error `-32004`) |
| `unsend` | `{messageId}` | `{message: Message}` (Undo Send: text and attachments cleared, `unsentAt` set; error `-32003` after 2 minutes) |
| `typing` | `{isTyping: Bool}` | `{}` |
| `markRead` | `{upToSeq: Int}` | `{}` (the read receipt; never moves the marker back) |
| `unfurl` | `{url}` | `{linkPreview: LinkPreview}` |
| `updateConversation` | `{pinned?, pinOrder?, muted?, markedUnread?, deleted?}` | `{conversation}` |
| `keepAudio` | `{messageId}` | `{message: Message}` |
| `notifyAnyway` | `{messageId}` | `{message: Message}` (my `deliveredQuietly` message only, else `-32602`; sets `notifiedAnyway`) |
| `audioPlayed` | `{messageId}` | `{}` |

`keepAudio` keeps an audio message (clears `expiresAt`, sets `kept`).
`audioPlayed` reports that I listened to someone's recording; it starts that
recording's 2-minute expiry, as Messages does.

`history` with `beforeSeq: null` returns the newest page. Messages are sorted
ascending by `seq`. `send` is idempotent on `clientMessageId`: a retry returns
the original message.

When `resumeAfterEventSeq` is given, the server replays every event after it
as `event` notifications, in order, then sends `replayDone`. If the gap exceeds
500 events it sends nothing and returns `lagged: true`; the client must refetch
the newest page and rebase.

`updateConversation` applies conversation list actions with Messages' rules:
pinning appends after the last pin unless `pinOrder` is given; at most 9
conversations (env `MAX_PINNED`) are pinned, and one more fails with `-32004
"pin limit"`; unpinning drops `pinOrder`; deleting unpins and clears
`markedUnread` (Hide Alerts stays). A deleted conversation is recoverable: a
new message from someone else, or `deleted: false`, brings it back. Every
change is pushed to the conversation's subscribed clients as `conversation`.

## Notifications (server to client)

`event` with params `{eventSeq, kind, ...}`:

- `message.created {message}`
- `message.updated {message}` (edit, reaction, delivery status, reply count)

`conversation {conversation}` carries the conversation after a list state
change. It has no `eventSeq`; `hello` returns the current state, so a client
resyncs on reconnect.

`typing {participantId, isTyping}` is ephemeral and carries no `eventSeq`.

`readState {lastReadSeq, unreadCount, headSeq}` goes to every connection on
the conversation whenever the shared read marker moves (`markRead` from any
device, my `send`, which reads the conversation, or `/admin/unread`).
`unreadCount` counts messages from others with `seq > lastReadSeq` as of
`headSeq`; later arrivals from others add to it until the next `readState`.
It carries no `eventSeq` and is not replayed: `hello` returns the current
marker.
`replayDone {}` ends a resume replay.

Event delivery is ordered per connection. Duplicates are possible; the client
dedupes on `eventSeq` and on message `id`.

## Types

```
Conversation {
  id, title, kind: "group"|"direct", participants: [Participant],
  pinned, pinOrder?, muted, markedUnread, deleted   // list state; pinOrder only when pinned
}
Participant  {
  id, name, initials, colorHex, isMe,
  notificationsSilenced?: true   // Focus on (direct recipient); omitted when off
  left?: true                    // left or was removed from the group; omitted otherwise
}
Message {
  id, seq, clientMessageId?, senderId, sentAt (epoch ms), text,
  replyToId?, replyCount, editedAt?, editCount?, unsentAt?,
  reactions: [{participantId, reaction}],
  attachments: [Attachment],
  status?: "sent"|"delivered"|"read", readAt?    // only on my messages
  mentions?: [Mention]                           // omitted when none
  textRuns?: [TextRun]                           // omitted when plain
  linkPreview?: LinkPreview   // when a URL opens or ends `text`
  effect?: Effect                                // "send with effect"
  system?: SystemEvent        // a group status row; `text` is "", `senderId` is the actor
  deliveredQuietly?: true     // mine, delivered while the recipient was silenced
  notifiedAnyway?: true       // I tapped Notify Anyway for it
}
SystemEvent {
  kind: "named"|"removedName"|"added"|"removed"|"left"|"changedPhoto"|"removedPhoto",
  targetId?,   // added / removed
  name?        // named: the new conversation name
}
LinkPreview {
  url, title?, siteName?, state: "loaded"|"loading"|"tapToLoad",
  image?: {url, width, height}, icon?: {url, width, height}
}
Attachment {
  id, kind: "image"|"audio", width, height, url,
  // audio only:
  durationMs, waveform: [Int 0-100] (peak levels, evenly spaced),
  transcript?, expiresAt? (epoch ms; absent = kept), kept?
}
Mention { participantId, location, length }      // UTF-16 range of text, sorted, non-overlapping
TextRun = { start, length, styles?: [TextStyle], effect?: TextEffect }
TextStyle  = "bold"|"italic"|"underline"|"strikethrough"
TextEffect = "big"|"small"|"shake"|"nod"|"explode"|"ripple"|"bloom"|"jitter"
```

A mention is the participant's first name in `text` (no "@"). `send` rejects
unknown participants and out-of-range or overlapping mentions with `-32602`.
`edit` keeps only the mentions whose text is unchanged at the same range.

```
Reaction = "heart"|"thumbsup"|"thumbsdown"|"haha"|"exclamation"|"question"
Effect   = "slam"|"loud"|"gentle"|"invisibleInk"                       // bubble
         | "echo"|"spotlight"|"balloons"|"confetti"|"love"|"lasers"
         | "fireworks"|"celebration"                                   // screen
```

`textRuns` carry iMessage formatting and animated text effects. `start` and
`length` count UTF-16 code units of `text`. Runs are sorted, non-overlapping
and non-empty; the server rejects out-of-range, overlapping or unknown values
with `-32602` and drops runs with neither styles nor an effect. `styles` come
back in the canonical order above. `edit` replaces the runs with its own, so an
edit without `textRuns` clears the formatting.

## HTTP

- `GET /media/<id>.png`: procedurally generated image, served after a latency
  delay.
- `GET /media/<id>.wav`: procedurally generated speech-like 16 kHz mono WAV
  for an audio attachment (waveform derived from the same syllables).
- `POST /upload` with raw image bytes and `Content-Type`: returns
  `{attachment}` usable in `send.attachmentIds`. Audio: `POST
  /upload?kind=audio&durationMs=<ms>&waveform=<0-100,...>` with the recording
  (`audio/wav` or `audio/mp4`) and optional `X-Transcript` (percent-encoded);
  a WAV's duration is read from the bytes when `durationMs` is omitted. Sending
  it makes an audio message that expires 2 minutes later unless kept.
- `GET /healthz`: `ok`.
- `POST /admin/burst?conversation=<id>&count=<n>`: make participants send `n`
  messages rapidly (pressure testing).
- `POST /admin/mention?conversation=<id>&target=<participantId>&from=<botId>`:
  a bot sends a message mentioning `target` (default: me) at once.
- `POST /admin/unread?conversation=<id>&count=<n>`: move the read marker so
  exactly `n` messages from others are unread (catch-up testing; the range
  may include my own messages, which real traffic never does). Boot leaves the
  last `GROUP_UNREAD` (60) and `DIRECT_UNREAD` (3) messages unread, all from
  others.
- `POST /admin/audio?conversation=<id>&count=<n>[&sender=<participantId>]`:
  one participant sends `n` audio messages back to back (auto-play testing).
- `POST /admin/say?conversation=<id>&sender=<id>&text=<s>&effect=<Effect>`: a
  participant types briefly, then sends one message (all params optional).
  Receiver-side effect testing. With a JSON body `{conversation, senderId,
  text, effect}` instead, the message posts at once and the sender may be me
  (deterministic link, data detector and layout fixtures).
- `POST /admin/system?conversation=group&kind=<kind>&actor=<id>&target=<id>&name=<s>`:
  a group status row now (actor defaults to a random member). It applies its
  effect first: `named`/`removedName` change the title, `left`/`removed` mark
  the member `left` (they stop typing and sending), `added` brings a former
  member back; each pushes `conversation`. Invalid changes (a member who left
  acting, adding a current member, removing or leaving as me, a status row
  in `direct`) return 400.
- `POST /admin/focus?conversation=direct&on=1|0`: the direct recipient's Focus
  (pushes `conversation` with `notificationsSilenced`).
- `POST /admin/disconnect`: drop every socket (reconnect testing).
- `POST /admin/knobs` JSON `{latencyScale, failRate, historyFailRate,
  duplicateRate, disconnectEverySeconds, botIntervalScale, botLinkRate, effectRate,
  statusEverySeconds, focusEverySeconds}`.

## Link previews

Messages turns a URL that opens or ends a message into a rich link card; a URL
in the middle stays inline text. The server attaches `linkPreview` to such
messages from canned, offline metadata (`links.ts`: GitHub PRs/issues/repo,
apple.com/iphone, YouTube, Spotify, Wikipedia, Hacker News) and a bare domain
card for anything else. Images are procedural PNGs at `/media/og_*.png`.
Messages from senders in `STRANGERS` (env, comma separated, default `austin`)
carry only `{url, state: "tapToLoad"}`; the client fetches the card with
`unfurl` when tapped. `unfurl` also backs the composer's pending preview
(300 to 1200 ms latency). Bots send link messages at `botLinkRate`.

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
  message ~5% of the time (an edit drops formatting). In `group`, ~12% of bot
  messages mention someone (half of those mention me); ~4% of group history
  mentions someone. About 6% of bot and history messages are formatted: half
  animate the whole message with a random text effect, half style one word.

Audio messages: ~1.5% of history (its own seeded rng, so the rest of history
is unchanged) plus, near each conversation's newest message, two consecutive
recordings from one participant and one of mine just above the boot unread
backlog (which is all from others). Bots send a recording 3% of
the time. Every recording has a spoken transcript.

Effects: `effectRate` (default 0.03) of bot text messages carry a random
effect; ~1.5% of generated history text messages do too.

## Group status rows and Focus

Status rows are messages with `system` (seq, paging, replay and dedupe as
usual). They never count as unread (`unreadCount`, `/admin/unread`). Group
history opens with Lawrence naming the conversation "cmux" (seq 1) and holds
a few more far from the newest pages: my photo change, a rename and rename
back, Leo leaving and being added again, another photo change. They replace
existing messages after history is generated, on their own seeded rng, so
every seq and every other message is unchanged.

Live, on a separate seeded stream (`SEED ^ 0x5747`), roughly every
`statusEverySeconds` (default 300, jittered 0.5x to 1.5x, scaled by
`botIntervalScale`; 0 stops it) a group member renames the group (40%),
changes its photo (20%), or a member leaves and is added back 20 to 90 s
later (40%).

The direct recipient's Focus flips on or off roughly every
`focusEverySeconds` (default 180, its own seeded stream `SEED ^ 0xf0c5`; 0
stops it). While it is on, my messages there become `delivered` with
`deliveredQuietly: true`.
