// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// Where the chat's goal sits with the composer hat (TaskGoalStrip.tsx `GoalStrip`, App.tsx). Leo,
/// 2026-11-09, on a reference goal pill: "i wonder hwo we wanna have it with the composer hat."
/// Compare them in the gallery's `agent-pane.composer-goal`.
export const goalHatPlace = defineExperiment({
  id: "composer-goal-place",
  title: "Composer hat: where the goal sits",
  description:
    "The goal row: at the top of the hat's glass, at its foot on the seam with the composer, or as a separate pill over the hat.",
  arms: {
    head: {
      label: "Heads the hat",
      description:
        "The hat's first row, in the same glass and rim as the running lines and the composer, its time and buttons in the lines' trailing columns.",
    },
    foot: {
      label: "Hat's foot",
      description: "The hat's last row, right over the composer, under the running lines and questions.",
    },
    pill: {
      label: "Own pill",
      description: "A separate rounded pill one gap over the hat, as the reference draws it.",
    },
  },
  defaultArm: "head",
});
