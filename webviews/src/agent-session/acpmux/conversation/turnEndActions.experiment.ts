// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Where a turn the agent ran on its own ends on its row of actions (Copy, Fork, Timeline, Read aloud,
/// More) when it ran calls and said nothing after them (Leo, 2026-11-21: "there's no buttons at the
/// bottom even thuogh you have visibly stopped doing things"). turns.ts `backgroundFooters`. Compare
/// the arms in the gallery's `agent-pane.turn-end-actions`.
export const turnEndActions = defineExperiment({
  id: "turn-end-actions",
  title: "Turn end actions",
  description: "Which turns the agent ran on its own, ending on calls with no reply, end on their row of actions.",
  arms: {
    every: {
      label: "Every ended turn",
      description:
        "Each turn the agent ran on its own and ended ends on its own row, as a prompt's turn does, whether it ended on a reply or on calls.",
    },
    last: {
      label: "Only the last",
      description:
        "A turn that ended on calls gets its row only while it is the chat's last; one that ended on a reply keeps its row as before.",
    },
    off: {
      label: "Reply only (before)",
      description: "Only a turn that ended on a reply gets its row: one of calls alone ends on its last call.",
    },
  },
  defaultArm: "every",
});
