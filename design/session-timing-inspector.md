# Session timing inspector

Leo: “you can see, you know, say the breakdown.”
Leo-Ask-Trace: ask-53075f1aa2

Open a chat's actions menu, ACP inspector, Timing. This adds a session axis to
its existing Wire and Session views. The turn is the parent bar; its recorded
message-to-agent and agent-to-first-output intervals are the child bars. Idle
space remains on the axis. This is elapsed journal time, not a CPU profile.
The existing per-turn Timeline remains the place to inspect tools and gaps.

Use the inspector's quiet rows, shared text and status colors, and tabular
numbers. The reference is the compact labelled breakdown in
`manaflow-ai/cmux-design-references/apps/codex/live/context-usage-breakdown-card.png`:
secondary labels, aligned totals, and little decoration. No new animation.
Gallery `agent-pane.inspector-timing` compares bars (chosen), compact tracks,
and stacked labels, plus an empty recording. The axis remains shared in all.

The daemon's existing `_acpmux/history` owns `startedAt`, `endedAt`, `wallMs`,
`toAgentMs`, and `firstModelMs`. Only recorded values are displayed. A missing
send or output stamp says unknown; a measured zero remains zero. Opening Timing
reads the latest 100 turns once. Closing and reopening refreshes the snapshot;
there is no timer or journal scan while the inspector is closed. Responses from
an unmounted or different session must never replace the selected session.

Settings > Advanced > Check Configuration re-reads the existing Settings query
and its Rust-owned diagnostics. It never writes settings or adds validation
rules. Checking disables repeat clicks; a failed read reports the error, never
a clean verdict. Live Settings updates keep using the same query cache.
`pages.configuration-check` covers clean, invalid, and unavailable owners.
