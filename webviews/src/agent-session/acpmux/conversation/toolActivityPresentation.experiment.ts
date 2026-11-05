// l10n-allow-file: gallery comparison controls, not shipped copy.
import { defineExperiment, experimentArm } from "../../../experiments/experiment";

export const toolActivityPresentation = defineExperiment({
  id: "tool-activity-presentation",
  title: "Tool activity presentation",
  description:
    "Compare the current per-harness transcript with T3 Code's live activity and completed-turn disclosures.",
  arms: {
    current: { label: "Current", description: "Existing per-harness folding." },
    t3: {
      label: "T3 Code",
      description:
        "Expandable live activity, then Worked for above the final reply. Full messages stay in the history.",
    },
  },
  defaultArm: "current",
});

export const usesT3Activity = () => experimentArm(toolActivityPresentation) === "t3";
