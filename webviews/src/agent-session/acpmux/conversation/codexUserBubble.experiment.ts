// l10n-allow-file: experiment metadata is developer-facing gallery/debug text.
import { defineExperiment } from "../../../experiments/experiment";

/**
 * A reversible first slice of the Codex look: the user prompt bubble's paint.
 * The baseline arm is the shipped behavior; the Codex arm consumes the public
 * bubble tokens supplied by a look stylesheet.
 */
export const codexUserBubbleLook = defineExperiment({
  id: "codex-user-bubble-look",
  title: "Codex user bubble",
  description: "Compare the current prompt bubble with the Codex look's tint and radius tokens.",
  arms: {
    baseline: {
      label: "Current",
      description: "Keep the current prompt bubble treatment.",
    },
    codex: {
      label: "Codex",
      description: "Use the Codex look's user bubble tint and radius tokens.",
    },
  },
  defaultArm: "baseline",
});
