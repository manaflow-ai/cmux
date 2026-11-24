# Agent pane host line

What the pane shows above the composer when the agent service (acpmux) is slow or unreachable. The
quiet "Reconnecting…" chip, drawn out of flow in `HostLineSlot`, follows the connection's state and
never a clock (Leo, 2026-11-22: "surely we can think of better fixes than random timing which can
shift"). A dropped socket, a handshake that waits for acpmux and a planned restart (`details.handoff`)
show nothing for as long as they last. Only a failed attempt marks the link down (App.tsx `linkDown`),
and the next connect clears it (hostRetry.ts `hostRecoveryLine`). A line of words shows only for a refusal
the host can't clear by itself, and it always comes with the one step that clears it (hostRetry.ts
`hostErrorShows`).

## Rule: no unactionable status rows

A state the person can't act on gets fixed, not narrated. Leo, 2026-11-22, after an update showed
"Not verified as you. Reconnecting your identity to the agent service…", "Reconnecting…" and
"Waiting for the agent service (0:46)  Restart agent service" over the composer: "remove all this
bullshit", "fix the root problem", and on the Restart: "who the fuck is going to click restart on
the agent service".

- No row is added or removed above the composer, in the header or in the sidebar for a state the
  person can't change: an identity being re-proved, a daemon starting, restarting, handing off or
  restoring, a connection coming back, a retry the app runs itself.
- Such a state heals by itself, and the fix goes where the wait comes from (acpmux, the host), never
  into words about it. A button that only does what the app should already do by itself (Restart
  agent service) is not an action: it is the bug, surfaced.
- If a long outage must show at all, it is the shared quiet chip (`ConnectionChip`), after the
  shared bound, out of flow, with no clock and no button. Never a sentence, never a ticking time.
- A line of words is allowed only when the person must do something and the line has that one step
  (Enable, Trust, Restart acpmux for another build's daemon holding the socket, Sign in, Reconnect a
  machine the person paused).

The check: `scripts/cmux-next/check-connection-notices.py` already refuses a connection state with no
bound and no action. It passes a state with a bound alone, which is how the three lines above got in;
narrowing "bound" to "drawn through the quiet chip" is the follow-up named in this rule's PR.

It says only what the person needs, and never asks them to do what the pane does by itself. Leo,
2026-11-12, after the machine hosting a chat's agent rebooted and the line read "Couldn't connect to
the agent. [Retry]" over two reassurance sentences: "the recovery needs to be a lot better and it
shouldn't talk so much bullshit"; on "Something went wrong, so that didn't go through. Try again.":
"try what? no, it should just automatically do stuff".

## States

Each state is drawn in the same zero-height slot, so one turning into another moves nothing.

- **Reconnecting** (`HostRecoveringLine`, and `HostUnavailableLine` while the pane asks again by
  itself): the "Reconnecting…" chip, muted, out of flow, no button, no clock, however long the outage
  or the handshake's wait (a machine rebooting, an
  agent service starting). acpmux's words, codes and commands never show. A message sent meanwhile
  stays in the composer ("Sending when ready") and goes once acpmux answers (sendWhenReady.ts, no
  deadline).
- **Failure** (`HostUnavailableLine` with `selfRetrying` false): only for what asking again can't
  change (a chat too large to open, another build's acpmux holding the socket): the plain reason
  (hostLine.ts) with its one action (Retry, or Restart acpmux) and Details.

The row is at least 24 px (a button's height). None is red and none animates.

## References

The live captures in `cmux-design-references/index.json`: `cmux/live/status-capacity-error-retry-display`
and `cmux/live/status-remote-agent-offline-reconnect`, whose quiet "The chat catches up once it
connects." is the tone the line follows.

## Gallery

`agent-pane.host-error`: `automatic` (picked: a long outage is only Reconnecting…), `outage-named`,
`outage-timed` and `outage-before` (the line Leo saw). The `waiting*` variants went with the waiting
line (2026-11-22): a running clock makes a wait the person can't shorten feel longer, and its Restart
was the app's job.
