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
- A steer that acpmux accepted reached Claude Code only at its next tool
  boundary, so a tool that runs for a long time (for example, `cmux-ci
  wait`) delayed it. Fixed 2026-10-26 (below).

## Send now by default (2026-10-26)

User (2026-10-26): Chief messages must reach the agent's ACP chat "with
interrupt by default".

- The Chief's default `tell` steers with `_meta.acpmux.steerNow` (optchat-chief
  `AgentPort::steer_now`). acpmux (`Hub::steer_turn`) then stops the agent's
  current step, as the pane's Send now (`_acpmux/queue_edit` `send_now`) does
  for a waiting steer. The turn goes on, with its context, and reads the
  message at once.
- acpmux never stops a running subagent or a background shell for it
  (claude_stdio `steer_now_tests.rs`); a foreground shell is stopped.
- `queue: true`, a peer's message (`peer_tell`) and the restart steer of an
  alive subagent (`control.rs`) still wait for the step.
- An acpmux without `steerNow` ignores the key: the old steer.
- Tests: acpmux `hub_integration/steer_now.rs`
  `a_steer_sent_with_steer_now_stops_the_step_at_once`; optchat-chief
  `tests/eval_acp.rs` (Chief fast eval group `acp`) and `acpmux_wire.rs`
  `a_steer_sent_now_carries_steer_now_over_the_wire`.

## Tests

`Native/OptChat/optchat-chief/tests/subagent_control.rs`:
`a_tell_to_a_running_subagent_that_cannot_steer_interrupts_it` (red first),
`a_queue_tell_waits_for_the_turn`, and
`queued_chief_tells_are_flushed_as_an_interrupt_on_reconnect`.

A Chief host restart is necessary: the running host keeps the old code.
