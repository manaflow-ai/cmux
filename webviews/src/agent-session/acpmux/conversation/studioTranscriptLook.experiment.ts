// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/** The first Studio look slice: transcript cards and the prompt bubble use six-point corners. */
export const studioTranscriptLook = defineExperiment({
  id: "studio-transcript-look",
  title: "Studio transcript corners",
  description: "Compare the Studio look's compact six-point transcript corners with the current appearance.",
  arms: {
    current: {
      label: "Current appearance",
      description: "Keep the existing shared twelve-point card and prompt corners.",
    },
    studio: {
      label: "Studio",
      description: "Use six-point corners for transcript cards, code blocks and the prompt bubble.",
    },
  },
  defaultArm: "current",
});
