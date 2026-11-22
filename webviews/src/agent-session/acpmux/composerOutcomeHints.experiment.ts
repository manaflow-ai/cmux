// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// How the empty composer names its responder and how the slash/mention lists preview their next
/// action. The default keeps the current composer copy and rows unchanged.
export const composerOutcomeHints = defineExperiment({
  id: "composer-outcome-hints",
  title: "Composer outcome hints",
  description: "How the composer shows the responding agent and the result of choosing a menu row.",
  arms: {
    now: {
      label: "Current",
      description: "Keep the current placeholder and slash and mention rows.",
    },
    agent: {
      label: "Agent name",
      description: "Name the agent that will answer in the empty composer.",
    },
    modes: {
      label: "Agent + modes",
      description: "Name the agent and show the / command and @ file modes in the placeholder.",
    },
    outcomes: {
      label: "Outcome hints",
      description: "Show the agent and modes, then preview each row's action and description.",
    },
  },
  defaultArm: "now",
});
