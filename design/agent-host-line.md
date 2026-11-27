# Agent pane host line

The line above the composer when the agent service (acpmux) is slow or unreachable. It shows only
after `HOST_ERROR_DEADLINE_MS` (25 s) of a recovery, or at once for a refusal the host can't clear
(hostRetry.ts `hostErrorShows`). Before that nothing shows.

It says only what the person needs, and never asks them to do what the pane does by itself. Leo,
2026-11-12, after the machine hosting a chat's agent rebooted and the line read "Couldn't connect to
the agent. [Retry]" over two reassurance sentences: "the recovery needs to be a lot better and it
shouldn't talk so much bullshit"; on "Something went wrong, so that didn't go through. Try again.":
"try what? no, it should just automatically do stuff".

## States

Each state is one row, so one turning into another moves nothing.

- **Reconnecting** (`HostRecoveringLine`, and `HostUnavailableLine` while the pane asks again by
  itself): "Reconnecting…", muted, no button, however long the outage (a machine rebooting, an
  agent service starting). acpmux's words, codes and commands never show. A message sent meanwhile
  stays in the composer ("Sending when ready") and goes once acpmux answers (sendWhenReady.ts, no
  deadline).
- **Waiting** (`HostWaitingLine`): "Waiting for the agent service (m:ss)", then **Restart agent
  service** as quiet underlined text: an optional step, never a filled button. Nothing under it.
- **Failure** (`HostUnavailableLine` with `selfRetrying` false): only for what asking again can't
  change (a chat too large to open, another build's acpmux holding the socket): the plain reason
  (hostLine.ts) with its one action (Retry, or Restart agent service) and Details.

The row is at least 24 px (a button's height). None is red and none animates.

## References

The live captures in `cmux-design-references/index.json`: `cmux/live/status-capacity-error-retry-display`
and `cmux/live/status-remote-agent-offline-reconnect`, whose quiet "The chat catches up once it
connects." is the tone the line follows.

## Gallery

`agent-pane.host-error`: `automatic` (picked: a long outage is only Reconnecting…), `outage-named`,
`outage-timed` and `outage-before` (the line Leo saw); `waiting` (picked), `waiting-restart`,
`waiting-before`, `waiting-one-line`, `waiting-disclosure` and `waiting-to-failure`. Naming the
machine is long at narrow widths and not what the person waits on; a running clock makes a wait they
can't shorten feel longer.
