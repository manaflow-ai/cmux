// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the pastes of a sent message join its typed words in the message's one text body
/// (ask-14d16a6247; Leo, 2026-11-07, of a dictated message pasted in three parts and drawn as three
/// cards: "Like just don't separate these out."). No arm draws a card, a fold or a gap of its own:
/// they differ only in the line breaks put where two runs meet (promptCollapse.ts `joinRuns`).
/// model.ts estimates each. Gallery `agent-pane.sent-one-body`.
export const sentPasteJoin = defineExperiment({
  id: "sent-paste-join",
  title: "Sent paste join",
  description:
    "Where a paste meets the message's other words in the sent bubble: as typed, a blank line, or a line break.",
  arms: {
    typed: {
      label: "As typed",
      description:
        "The words between the pastes as the draft had them, so the bubble reads as the composer did; a record that kept only its text blocks reads as recorded.",
    },
    paragraph: {
      label: "Blank line",
      description: "Each paste its own paragraph: a blank line where two runs meet, blank lines at their ends dropped.",
    },
    line: {
      label: "Line break",
      description: "One line break where two runs meet, blank lines at their ends dropped.",
    },
  },
  defaultArm: "typed",
});
