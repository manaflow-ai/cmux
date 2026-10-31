// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// How the New Tab composer's scope line names Auto's destination (ComposerContext, environment
/// picker): where the chat runs, and that Auto chose it. Compare them in the gallery's
/// `agent-pane.composer-auto-scope`.
export const autoScopeLook = defineExperiment({
  id: "auto-scope-look",
  title: "Auto scope line",
  description: "How the New Tab scope line names the destination Auto chose: Cloud, this Mac or a machine.",
  arms: {
    tag: {
      label: "Destination, Auto tag",
      description: "The destination's icon and name, as an explicit pick shows it, then a quiet Auto after it.",
    },
    dot: {
      label: "Auto · destination",
      description: "One label: Auto, a middle dot, then the destination, with the destination's icon.",
    },
    icon: {
      label: "Auto icon",
      description: "Auto's own icon in place of the destination's, then the destination's name alone.",
    },
  },
  defaultArm: "dot",
});
