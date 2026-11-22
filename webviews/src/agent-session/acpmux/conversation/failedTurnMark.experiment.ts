// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a failed turn's footer row says the turn failed (G04: a turn that ended in an API error drew no
/// row of its own, no Copy and no mark). The error card above says why; the row under it carries the
/// mark, Copy and the turn's time in the mark's tooltip, as every finished turn's row does. Compare
/// the arms in the gallery's `agent-pane.turn-end-footer`.
export const failedTurnMark = defineExperiment({
  id: "failed-turn-mark",
  title: "Failed turn mark",
  description: "How a failed turn's footer row marks that the turn failed.",
  arms: {
    alert: {
      label: "Alert circle",
      description:
        "The failure glyph (a circled !) in the failure ink after the buttons, as Claude marks its error card.",
    },
    cross: {
      label: "Cross",
      description: "A small cross in the failure ink after the buttons.",
    },
    word: {
      label: "Failed",
      description: "One muted word, Failed, after the buttons, as a stopped turn's Stopped reads.",
    },
  },
  // Closest to Claude desktop: its error card leads with a circled ! in the failure ink
  // (claude/live/status-subagent-failure-and-resume).
  defaultArm: "alert",
});
