# Composer status dot

One 6 px dot in the composer footer, where the machine row was, with a card that gives a rundown of
what is going on. Leo, 2026-11-22, after the "agent service" chip drew over transcript text: "if you
have these random health checks they should've just been in an unobtrisive spot say near the bottom
of the composer some sort of status dot that fades in and when you hover or click into it ... and
just have that be able to give you rundowns of various statuses. ... hey there's space at the bottom
of the composer. what else could we add that fits? metadata about stuff is one."

## Where the words come from

acpmux decides them (`cmux-tui/crates/acpmux/src/protocol/composer_status.rs`): the session summary's
`composerStatus` (`items`, `facts`) and each peer link's `status`. The pane only renders. It adds
just what it alone knows: its own reconnect to acpmux ("Reconnecting…", "Restoring sessions…", under
`hostRecoveryLine`'s same 10 s / 25 s rule) and a held send ("Sending when ready"). Each item names
a catalog key. A key this build does not know draws nothing, and never the raw key.
(composerStatusModel.ts)

## The dot

- Its box is always there, and it fades with opacity only: no spinner, no words, and nothing moves.
  It never covers the transcript and never blocks a send.
- Its ink is the worst item due now: info muted, attention amber, problem red. An item with
  `showAt` waits on one timer.
- With nothing to say, a connected remote chat keeps the green dot. A local chat shows no dot, or a
  faint one when footer facts are on.
- A problem is announced once, through a polite live region.
- A remote chat on an older acpmux (no `composerStatus`, no link `status`) keeps MachineLinkStatus
  as before.

## Peek and pin

The table is data: `schemas/composer-status/peek-pin.json`. `peekPin.ts` only looks rows up.

- A hover peeks after the tooltip delay, at once when a tooltip is warm, and it ends after the card
  grace, through the hover bridge.
- A click, a tap, or Enter/Space pins it. Enter/Space also focuses the card's first action.
- Pinning keeps the same card. Only its "esc Close" line appears, and that line's height is kept
  while it peeks.
- A pin ignores hover. A click on the dot, a press outside, or Escape closes it. Escape returns
  focus to the dot with no ring.
- After a click closes the card, it does not peek again until the pointer has left the dot (the
  table's fourth state, `held`).

## Footer facts (experiment `composer-footer-facts`)

- `off` (default): statuses only.
- `pulse`: the card adds a Session list (folder as its last two segments, context %, turn time).
  Running subagents and queued prompts show as counters beside the dot, in fixed slots with "9+".
- `door`: the Session list only, behind a faint resting dot.

Gallery: `agent-pane.composer-status-dot`.
