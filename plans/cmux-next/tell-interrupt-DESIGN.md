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

## Follow-up (2026-10-20, same branch)

- acpmux stops a running turn for any prompt that does not ask to queue
  (`_meta.acpmux.queue`, `acpmux send --queue`, config `busyPrompt`), so a
  `queue` tell skips the steer and is sent as queued
  (`AgentPort::start_prompt_queued`).
- A steer Claude Code has not read within `steerReadDeadlineMs` (default
  500) stops its running tool (`_acpmux/steer_now`): the turn goes on and it
  reads every waiting message, in order. A tell during a long tool is read in
  well under 1 s (`tests/hub_integration/tell_delivery.rs`).
- The agent pane: Return mid-turn steers an agent that steers, else stops the
  turn and runs next; Command-Return stops the turn now; Option-Return
  queues. The hints say so in all 21 languages.

## Tests

`Native/OptChat/optchat-chief/tests/subagent_control.rs`:
`a_tell_to_a_running_subagent_that_cannot_steer_interrupts_it` (red first),
`a_queue_tell_waits_for_the_turn`, and
`queued_chief_tells_are_flushed_as_an_interrupt_on_reconnect`.

A Chief host restart is necessary: the running host keeps the old code.
