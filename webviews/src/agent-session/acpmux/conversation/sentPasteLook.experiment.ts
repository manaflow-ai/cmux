// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a block the composer sent as a paste draws in the sent bubble (ask-792a64a12f; Leo,
/// 2026-11-07: "we do not want to have this card thing going on, this double card thing ... we
/// don't want to show it as pasted text. We want to show the actual characters. We don't want to
/// limit this that hard"). Every arm is estimated before it draws (model.ts), so a sent prompt
/// never resizes once it lands. Gallery `agent-pane.sent-bubble-size` `long-paste`.
export const sentPasteLook = defineExperiment({
  id: "sent-paste-look",
  title: "Sent paste",
  description: "How a paste reads inside the person's sent bubble: as its own text, one label row, or a card.",
  arms: {
    text: {
      label: "Text",
      description:
        "The paste is the bubble's own text, its characters whole, under the prompt's one Show more; a paste another agent wrote keeps a quiet 'Pasted from' line over it.",
    },
    row: {
      label: "Row",
      description: "One quiet row in the bubble, 'Pasted text · N characters', that opens to the paste in place.",
    },
    card: {
      label: "Card",
      description: "Before: a tinted card inside the bubble of the paste's first three lines over its label.",
    },
  },
  defaultArm: "text",
});
