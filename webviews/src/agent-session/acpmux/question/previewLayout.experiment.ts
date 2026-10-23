// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Where a question card draws the preview of an option (Claude Code's AskUserQuestion `preview`:
/// an ASCII mockup or code sample per option, shown while that option is focused). `split` (the
/// default) is Claude Code's own shape: a narrower option list on the left and the preview filling
/// the rest of the card's height on the right, wrapping under the list when the pane is narrow.
/// `even` is the card before 2026-10-22: list and preview share the width. `below` puts the preview
/// under the whole list, full width. `inline` opens it under the focused option. Dogfood switches
/// from `cmux.experiments`: {"question-preview-layout":"below"}.
export const questionPreviewLayout = defineExperiment({
  id: "question-preview-layout",
  title: "Question card preview layout",
  description:
    "Where an agent question's option preview draws: beside a narrower list (Claude Code), beside an equal list, under the list, or under the focused option.",
  arms: {
    split: {
      label: "Split",
      description: "A narrower list on the left, the preview filling the card's height on the right.",
    },
    even: { label: "Even", description: "List and preview share the width (the card before 2026-10-22)." },
    below: { label: "Below", description: "The preview under the whole list, full width." },
    inline: { label: "Inline", description: "The preview opens under the focused option, in the list." },
  },
  defaultArm: "split",
});

export type QuestionPreviewLayout = keyof typeof questionPreviewLayout.arms;
