// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Where a failed turn's cmux CodeRouter action sits (Lawrence 2026-10-23: "good opportunity for
/// upsell here"): beside Switch model on a key, sign-in or capacity failure (CodeRouterOffer.tsx).
/// Compare the arms in the gallery's `agent-pane.turn-error-card` (its `coderouter-*` states).
export const codeRouterOffer = defineExperiment({
  id: "coderouter-offer",
  title: "CodeRouter on a failed turn",
  description: "How a key, sign-in or capacity failure offers cmux's own route beside Switch model.",
  arms: {
    button: {
      label: "Third button",
      description: "An outlined button after Switch model; the way out keeps the one filled button.",
    },
    primary: {
      label: "Filled button",
      description: "CodeRouter takes the filled button, Switch model and Retry outlined after it.",
    },
    link: {
      label: "Link in the cause",
      description: "No button: a link after the cause line, the buttons as before.",
    },
  },
  defaultArm: "button",
});
