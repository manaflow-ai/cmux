// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a failed turn shows its failure (Leo 2026-10-22: "we need to have prettier errors"): the
/// cause in one human line, the way out first, and the agent's own words under Details with Copy.
/// The arms differ only in the surface; compare them in the gallery's `agent-pane.turn-error-card`.
export const turnErrorCard = defineExperiment({
  id: "turn-error-card",
  title: "Turn error card",
  description: "How a failed turn draws its cause, its way out and the agent's own error.",
  arms: {
    card: {
      label: "Glass card",
      description: "A glass card where the answer would be: an icon and the cause, the way out, Details.",
    },
    rail: {
      label: "Accent rail",
      description: "No surface: a thin warning rail beside the cause, the buttons under it.",
    },
    note: {
      label: "Quiet note",
      description: "The note as before, in the transcript's text, with the new cause line and way out.",
    },
  },
  defaultArm: "card",
});
