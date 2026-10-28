# Chief turn tools: send, stop, sleep

User (2026-10-20, msg 5967, a screenshot of one Chief bubble that answered two
separate messages): "you probably should have replied twice separately to the
two different messages ... have a send message tool instead of just using the
final assistant response ... `send message`, which needs to support multimedia
... A `stop` tool call ... detect if you call this `stop` tool ... so you don't
have to generate a final response ... another tool called `sleep` for a period
of time so that you can do looping smarter. Just think from first principles."

Builds on plans/cmux-next/chief-replies-reactions-DESIGN.md (a287/a220:
`react`, `reply`, DM threads) and the media replies of `brain/media.rs`.

## First principles

A Chief turn today has one output channel: the model's last text, posted when
the turn ends. That couples three separate things:

1. **What to say** (one message, always at the end, always one bubble).
2. **When the turn is over** (only when the model stops generating text).
3. **When to look again** (only when someone else sends a message).

So the Chief answers two asks in one bubble, writes a final "Done." it does
not need (a full extra model request, paid uncached on every tool-heavy turn),
says `NO_REPLY` as a magic string, and cannot say "check this again in 20
minutes" without a subagent or a busy loop.

The fix is to give each concern its own tool, so the model's final text is
optional:

| Concern | Tool | Effect |
|---|---|---|
| Say something | `send` | Posts one message **now**: text, files, images, videos, links; top level or in the thread of a message. Call it once per ask. |
| Be done | `stop` | Ends the turn **now**. Nothing more is generated or posted. |
| Look again later | `sleep` | Ends the turn now and wakes the Chief later with a note, without polling. |

All three are Chief-only (subagents report through their final text, which
already reaches the Chief as `[aN] report`).

## `send {text?, attachments?, reply_to?}`

- `text`: Markdown. Every rule of a turn reply holds: subagent ids become
  links, URL lines get link cards, a Markdown image of a local file is sent as
  the picture or video (`brain/media.rs`).
- `attachments`: a list of local paths (`/abs`, `~/rel`, `file://`) or
  `http(s)` URLs. A path is uploaded as an attachment part of the message:
  pictures and videos show inline (png, jpeg, gif, webp, heic, mp4, mov), any
  other file (pdf, md, html, zip, json, log, ...) as a file attachment, of any
  size (read from disk a chunk at a time). A URL is added as its own line (it
  gets a link card). A path that does not exist or is empty is refused before
  anything is posted, so the model can fix the call. At least one of `text` and
  `attachments` is needed.
- `reply_to`: the line id of a user message (as `reply` takes): the message
  goes into its thread. Without it, the message posts at the top level.
- Each call is one message, posted at once, through the outbox (retries,
  rate limits, idempotency): a repeat of the same call in one turn is a noop.
- `reply(id, text)` stays and is `send(text, reply_to=id)`.

Why not let any Markdown link of a local file upload it? The Chief links files
in its replies all the time (`[REPORT.md](file:///…)`); uploading every one
would spam attachments. An attachment is an explicit act.

## `stop {}`

- Ends the running turn at once: the host takes the call on its tools socket,
  answers it, and stops the acpmux session the way `chief.stop` does
  (`session/cancel`, resent until the turn ends; a running tool call finishes
  first, and `stop` itself returns at once). No extra model request runs to
  write a final reply.
- The turn's final text, if any, is not posted. A turn stopped this way is not
  a failure: no failure note, no cut-and-retry, no "turn stopped" text. It
  still closes its messages (the done marker of a silent turn), unlike an
  owner stop, because the Chief finished the work on purpose.
- Outside a turn it is a noop (`outcome: noop. no turn is running`).
- `NO_REPLY` keeps working for older prompts and other hosts. The prompt now
  asks for `stop` instead.
- ACP has no "end turn from a tool" request. Cancelling the session after the
  tool answered is the ACP-level equivalent, and it works on every harness
  acpmux runs (Claude Code, Codex, OpenCode). No acpmux change is needed.

## `sleep {seconds, note?, until?}`

- Ends the turn (as `stop`) and saves a wake: after `seconds` (30 s to 24 h)
  the host queues a note `[wake] <note>` that starts a normal turn, with the
  whole view. The note says when it was asked for and why.
- `until`: `time` (default) wakes at the time whatever else happens.
  `event` drops the wake when a user message or a subagent report starts a
  turn first: "wake me when a12 reports, or in 30 minutes at the latest".
- Saved in the host state (`wakes`), so a wake survives a host restart; one
  that came due while the host was down fires at start.
- At most 8 pending wakes; `sleep {seconds: 0}` clears them all. The answer
  lists what is pending.
- Why not block inside the turn? A held turn keeps a session open, blocks
  every message behind it (or is interrupted by it), and burns the idle-limit
  watchdog. Ending the turn and waking later costs nothing while asleep: no
  process, no request, no polling. The brain's own timer (`next_timer`) wakes
  it, the same one the outbox uses.

## Other tools considered

| Tool | Verdict |
|---|---|
| `edit {id, text}` / `retract {id}` own message | Useful (fix a typo, take back a wrong answer). The owner has `message.edit`/`retract`; the Chief needs the posted message id of its own sends. **Next**, not in this slice. |
| `typing {on}` | The host already shows typing while a turn runs. **No.** |
| `ask {question, options}` (buttons in the chat) | Good for the "reply X or Y" questions; needs Home UI for choice chips. **Later**, with a347's thread UI. |
| `show {path|url}` (open in the Home right column) | a331 already opens previews after a report. **Owned by a331.** |
| `schedule {cron, note}` (recurring wake) | `sleep` with a note that says "sleep again" covers it without a cron store. **No** for now. |
| `send` to a group / another conversation | Group replies already thread by membership. **Later.** |

## Prompt

The default "Turns" paragraph (`prompt::CHIEF_TURNS`) now says: answer each
separate ask with its own `send` (threaded by `reply_to` when other messages
came after it), react `ack` when only an acknowledgement is needed, call
`stop` when nothing else needs saying instead of a closing text, and `sleep`
to look again later instead of waiting. The user's own instructions still
come after it and win.

## Coordination

- a287/a220 own `react`/`reply` (d9cf9bd3f1f, 87dd08ff713, 61cc560714c);
  `send` reuses their thread and outbox code; `reply` stays.
- a298 owns steer/interrupt in acpmux. `stop` uses the host's existing
  interrupt path (`Interrupt::request`, `session/cancel`), not a new acpmux
  call, so it does not touch a298's work.
- a331 (right-column previews) and a347 (reply thread UI) render what `send`
  posts; no new part types are added.

## Going live

The host is `optchat-chief`. The tools reach the Chief after a nightly that
contains this change and a restart of the Chief host (the Chief's turns read
the tool list at session start). acpmux and the app need no change.

## Tests (failing first)

`Native/OptChat/optchat-chief/tests/chief_turn_tools.rs`, with the fake owner
and agents harness:

- `send` posts a top-level message at once; with `reply_to` it goes into that
  message's thread; a repeat is a noop.
- `send` with a file attachment uploads it and posts an attachment part; a
  missing file is refused and posts nothing.
- `stop` during a turn cancels the session; the turn's final text is not
  posted and no failure note is logged; outside a turn it is a noop.
- `sleep` ends the turn, saves a wake, and the wake starts a turn with the
  note when it is due; `until: event` drops it when a user message comes first.
- The MCP tool list has `send`, `stop`, `sleep` for the Chief, not for a
  subagent.
