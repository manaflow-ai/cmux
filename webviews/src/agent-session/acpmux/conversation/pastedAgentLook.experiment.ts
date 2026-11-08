// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a paste that reads as another agent's output draws in the person's message (ask-fa4c523fa8;
/// Leo, 2026-11-06: "it should be automatically attributable, so it doesn't just pass off as one of
/// my messages"). Every arm keeps the card's height, so a row never moves when its echo or an arm
/// changes. Gallery `agent-pane.user-bubble` `pasted-agent-*`.
export const pastedAgentLook = defineExperiment({
  id: "pasted-agent-look",
  title: "Pasted agent text",
  description:
    "How a paste that reads as another agent's handoff or report is set apart from the person's own words in their message.",
  arms: {
    rule: {
      label: "Rule",
      description:
        "The card's label names the agent (Pasted from Codex) with its glyph, and an accent rule runs down the card's left edge.",
    },
    label: {
      label: "Label",
      description: "Only the card's label changes: Pasted from Codex, with its glyph.",
    },
    badge: {
      label: "Badge",
      description: "The label stays Pasted text, and a small pill with the agent's glyph and name leads it.",
    },
  },
  defaultArm: "rule",
});
