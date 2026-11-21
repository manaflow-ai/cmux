// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a failed subagent's line reads in the transcript (SubagentDoneLine.tsx). Leo, 2026-11-03, on
/// three "Subagent failed" lines drawn all in red, their titles in grey chips cut short, and their
/// Retry buttons floating after text of every length: "this ui is pretty awkward looking". Compare
/// the arms in the gallery's `agent-pane.subagent-retry`.
export const failedLineLook = defineExperiment({
  id: "subagent-failed-line",
  title: "Subagent failed: the line's look",
  description:
    "A failed subagent's line: one fixed column grid with red only on its mark, the same quiet line in the sentence's flow, or the line as it was, all in red.",
  arms: {
    grid: {
      label: "Quiet grid",
      description:
        "Mark | title | short reason | Retry | time, the same columns on every failed line; the title in plain text, red only on the mark.",
    },
    quiet: {
      label: "Quiet flow",
      description: "Red only on the mark and plain text for the title, but Retry still follows the words.",
    },
    loud: {
      label: "Before",
      description: "As it was: the whole line in red, the title in a chip, Retry after the words.",
    },
  },
  defaultArm: "grid",
});
