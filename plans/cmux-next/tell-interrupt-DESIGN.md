# Chief `tell`: interrupt by default

User (2026-10-20), with a screenshot of a subagent composer that held two Chief
messages under "Queued · Sends after this turn": "We need a default behavior
for you to interrupt instead of queuing."

## Cause

`Brain::tell` (`Native/OptChat/optchat-chief/src/brain/spawns.rs`) sends a
running subagent a steer (`session/prompt` with `steerOnly`). acpmux refuses
the steer (`steer.unavailable`) when the harness cannot steer now. The Chief
then sent the message as a plain prompt, and acpmux queued it after the
running turn. A subagent in a long turn then read the message only at the
end of that turn, which can take an hour.

## Change

- Default (`tell(id, message)`): steer first. If the steer is refused, the
  host interrupts the turn. It uses the same path as
  `control(action: "interrupt", message)`: it records `after_stop`, sends
  `session/cancel`, and the message becomes the next prompt once the cut turn
  ends. The context stays, and the cut turn reports nothing. If the cancel
  fails, the message is queued, as before, and the host logs why.
- Opt-in `tell(id, message, queue: true)`: the old behavior, for
  low-priority FYIs. The host steers if it can, else queues after the turn.
- A second tell while an interrupt is still pending is appended to the
  pending `after_stop` and goes in the same next prompt.
- Flush on change: when the host reconnects or restarts
  (`reconcile_spawns`), for each running subagent it reads the subagent's
  events since its floor. It finds each Chief tell still in the acpmux queue
  (`queued` with prompt id `optchat-tell:…`, not run or removed later). It
  removes each one (`_acpmux/queue_remove`) and sends the texts together as
  one default tell, which interrupts the turn.

## Not changed

- The human composer (`webviews/src/agent-session/acpmux/Composer.tsx`) does
  not share this path. There, Enter queues and ⌘Enter steers or interrupts.
  This follows Claude's composer (Leo, 2026-10-18), and
  `composer-queued-placeholder.test.tsx` pins it. To change those keys is a
  separate product decision. It is not part of this change.
- A steer that acpmux accepted reaches Claude Code only at its next tool
  boundary. A tool that runs for a long time (for example, `cmux-ci wait`)
  still delays it. A deadline that converts a pending steer into an
  interrupt is possible follow-up work.

## Follow-up (a298, 2026-10-20)

- acpmux interrupts by default: a `session/prompt` sent while a turn runs
  stops that turn and runs next unless it asks to queue (`_meta.acpmux.queue`,
  `acpmux send --queue`, config `busyPrompt: "queue"`). A `queue` tell skips
  the steer and is sent as queued (`AgentPort::start_prompt_queued`).
- Gap 2 closed: a steer Claude Code has not read within
  `steerReadDeadlineMs` (default 500) stops its running tool
  (`_acpmux/steer_now`); the turn goes on and Claude reads every waiting
  message, in order. Codex takes a steer at once.
  `cmux-tui/crates/acpmux/tests/hub_integration/tell_delivery.rs` checks that
  tells sent during a 30 s tool are read within 1 s, in order.
- The human composers keep their keys: the agent pane's Enter and the acpmux
  TUI's Enter mid-turn now send `queue: true`, so they still queue.

## Tests

`Native/OptChat/optchat-chief/tests/subagent_control.rs`:
`a_tell_to_a_running_subagent_that_cannot_steer_interrupts_it` (red first),
`a_queue_tell_waits_for_the_turn`, and
`queued_chief_tells_are_flushed_as_an_interrupt_on_reconnect`.

A Chief host restart is necessary: the running host keeps the old code.
