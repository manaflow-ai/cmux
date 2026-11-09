# Agent pane host line

The line above the composer when the agent service (acpmux) is slow or unreachable. It shows only
after `HOST_ERROR_DEADLINE_MS` (25 s) of a recovery, or at once for a refusal the host can't clear
(hostRetry.ts `hostErrorShows`). Before that nothing shows.

It answers what the person wonders first. Leo, 2026-11-06, about "Waiting for the agent service
(8:25)": "has my app completely crashed? Should I be restarting it?"

## States

Both states are the same two rows at the same heights, so one turning into the other moves nothing.

- **Waiting** (`HostWaitingLine`): "Waiting for the agent service (m:ss)". Under it, muted: "cmux is
  still running, and your chats are kept. It keeps retrying on its own." Then **Restart agent
  service** as quiet underlined text: an optional step, never a filled button, never the lead.
- **Failure** (`HostUnavailableLine`): the plain reason (hostLine.ts) with Retry (or Restart acpmux
  when another build's acpmux holds the socket) and Details. The same muted row under it; it leaves
  out "retrying on its own" when asking again can't change the answer (a chat too large to open,
  another build's acpmux). acpmux's own words, codes and commands stay behind Details.

The message row is at least 24 px (its button's height) and the note row at least 20 px. Neither is
red, neither animates, and the note wraps instead of cutting off the answer.

## References

The live captures in `cmux-design-references/index.json`: `cmux/live/status-capacity-error-retry-display`
(Leo's screenshot for this ask) and `cmux/live/status-remote-agent-offline-reconnect`, whose quiet
"The chat catches up once it connects." is the tone the note follows.

## Gallery

`agent-pane.host-error`: `waiting` (picked), `waiting-restart`, `waiting-before`, `waiting-one-line`,
`waiting-disclosure` and `waiting-to-failure`. The one-line version cuts off the reassurance at
narrow and normal widths, and the disclosure hides it behind a question, so the picked version keeps
it as its own row.
