// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// A small outcome-shaped ask affordance for the agent composer. The default stays off while the
/// team tries whether a separate done-when field makes short asks easier to judge.
export const outcomeAsk = defineExperiment({
  id: "outcome-ask",
  title: "Outcome-shaped ask",
  description: "Add an optional Done when field and send it with the ask as a checkable outcome.",
  arms: {
    off: {
      label: "Off",
      description: "Keep the existing composer and prompt payload unchanged.",
    },
    on: {
      label: "Done when field",
      description: "Show a Done when field and append its text to the sent ask.",
    },
  },
  defaultArm: "off",
});
