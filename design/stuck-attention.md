# Stuck agent attention

A running chat can need attention while its agent continues working. The daemon reports a repeated
tool failure or an applied and reversed edit as `loopEpisode`; its existing `turn.stalledSince`
reports a silent turn. Neither signal changes the agent's scheduling state.

The chat pane gets a quiet amber inset ring and one compact diagnosis above the composer. The
diagnosis stays on one line, with the full text available on hover. The action reads **Nudge with
hint**. It prefixes an editable suggestion to the existing draft and focuses the composer; clicking
it never sends a message or stops the agent.

The start state is an ordinary running chat. Attention appears without moving the transcript or
composer. A successful tool call clears a loop episode; ending the turn, stopping, or closing the
session removes attention. The ring and diagnosis leave together. There is no animation, pulse,
timer, or observer in the UI, including with Reduce Motion enabled.

The reference is the quiet composer and compact utility controls in the private design collection's
live composer captures (`cmux-design-references/index.json`). Existing warning, typography, spacing,
and surface tokens supply the treatment.

Gallery: `agent-pane.stuck-banner` contains repeated-failure, reversed-edit, narrow-copy, and silence
states. The compact diagnosis with an inset ring is the selected treatment. The full chat gallery
exercises the actual composer, draft preservation, and the attention lifecycle.

The main sidebar ring is a follow-up dependent on the React sidebar migration (private hq#7889).
