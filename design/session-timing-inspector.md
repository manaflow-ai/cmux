# Session timing inspector

Leo: "like the gaps between message and sending" (ask-b1c5ff6a36), and
"you can see, you know, say the breakdown."

Open a chat's ACP inspector, Timing. Each turn is a parent bar on one session
axis; under it, three contiguous child bars as acpmux recorded them
(`_acpmux/history`, acpmux `hub/history_timing.rs`):

1. Message to agent (`toAgentMs`): the message accepted to the prompt written to
   the agent (an agent start or resume inside the prompt, its checks).
2. Queued (`queuedMs`, `queuedOn`): the prompt held behind the agent's own work
   or a compaction. Drawn only when acpmux recorded a hold.
3. Agent to first output (`firstModelMs`): from there to the first stream event
   or tool call.

The row's totals are message to first output (the sum) and the turn's wall time.
Idle space between turns stays on the axis. This is journal time, not a CPU
profile; the per-turn Timeline remains the place for tools and gaps inside a turn.

Only recorded values show: a missing stamp says unknown, a measured zero stays
zero, and no client clock runs for an open turn. Opening Timing reads the latest
100 turns once; Refresh reads again; nothing reads while the tab is closed. A late
answer for another chat never replaces the selected one.

Look: the inspector's quiet rows, tabular numbers, status colours (send warning,
queued warning at reduced opacity, first output accent). No new motion.
Gallery `agent-pane.inspector-timing` compares bars (chosen), compact tracks and
stacked labels, plus an empty recording.
