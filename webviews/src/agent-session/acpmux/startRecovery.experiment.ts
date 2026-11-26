// l10n-allow-file: gallery experiment descriptions, not product copy.
import { defineExperiment } from "../../experiments/experiment";

// All arms require Labs > Show Preview Features in the live app (default off).
export const startRecoveryLook = defineExperiment({
  id: "start-recovery",
  title: "Start recovery",
  description:
    "A missing or signed-out local agent's existing Install or Sign in action in a dismissible recovery dialog.",
  arms: {
    compact: {
      label: "Compact side",
      description: "Small illustration beside the reason, actions below.",
    },
    centered: { label: "Centered", description: "Illustration above the reason and actions." },
    horizontal: {
      label: "Horizontal",
      description: "Illustration, reason and actions share a wrapping row.",
    },
  },
  defaultArm: "compact",
});
