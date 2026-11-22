// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The mark by a sender acpmux could not verify (UnverifiedMark.tsx). Leo, 2026-11-22, on the small
/// speech bubble with a "?" after a sender's name: "this stupid tiny question mark symbol is too
/// small/weird/not really representative of whatever the heck you guys are trying to say, i think."
/// The bubble was the catalog's "Agent asked a question" glyph (`agent.question`): it said question,
/// not "who sent this is not proven". Compare the arms in the gallery's `agent-pane.verified-sender`.
export const unverifiedMarkLook = defineExperiment({
  id: "unverified-sender-mark",
  title: "Unverified sender: the mark",
  description:
    "What sits after a sender's name when acpmux could not prove who sent it: the catalog's warning glyph at the row's icon size, the word Unverified, or the small question bubble it was.",
  arms: {
    warning: {
      label: "Warning glyph",
      description:
        "The icon catalog's own Warning / unverified glyph (status.warning), muted, at the row's 14px icon size; the tooltip says what was not proven.",
    },
    word: {
      label: "Word",
      description: "The muted word Unverified after the name, no glyph; the tooltip says what was not proven.",
    },
    before: {
      label: "Before",
      description: "As it was: a 12px speech bubble with a question mark (the 'agent asked a question' glyph).",
    },
  },
  defaultArm: "warning",
});
