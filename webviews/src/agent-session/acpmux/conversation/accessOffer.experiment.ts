// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a turn the cmux model router refused for want of credits offers the ways in (Leo 2026-10-26:
/// "if user picks a model they don't have api key, we offer them to add credits or add their own api
/// key"): Add Credits… and Add API Key… on the failed turn's card (TurnRows.tsx, accessOffer.ts).
/// Compare the arms in the gallery's `agent-pane.access-offer`.
export const accessOfferLook = defineExperiment({
  id: "access-offer",
  title: "Add credits or your own key on a refused turn",
  description: "How a turn refused for want of cmux credits offers Add Credits and Add API Key.",
  arms: {
    "credits-first": {
      label: "Credits filled",
      description: "Add Credits takes the filled button, Add API Key outlined beside it, then Retry and Switch model.",
    },
    "key-first": {
      label: "Key filled",
      description: "Add API Key takes the filled button, Add Credits outlined beside it, then Retry and Switch model.",
    },
    link: {
      label: "Links in the cause",
      description: "No new buttons: both as links after the cause line; Retry stays the filled button.",
    },
  },
  defaultArm: "credits-first",
});
