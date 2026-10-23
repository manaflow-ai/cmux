// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a failed tool call says why (Leo 2026-10-22: "we need to have prettier errors"): the row
/// says what happened in a word (blocked, denied, timed out, Exit 1, failed) and the cause is one
/// line in the tool's own words; the raw result stays in the opened call. The arms differ only in
/// where the cause sits; compare them in the gallery's `agent-pane.tool-errors`.
export const toolErrorLook = defineExperiment({
  id: "tool-error-look",
  title: "Tool error look",
  description: "Where a failed tool call's one-line cause sits: under the row, on the row, or in a small card.",
  arms: {
    line: {
      label: "Quiet line",
      description: "The cause on one dim line under the row, cut to the width; the opened call has the rest.",
    },
    inline: {
      label: "On the row",
      description: "No new line: the cause follows the call's words on its own row, cut to the width.",
    },
    card: {
      label: "Compact card",
      description: "A small glass card under the row with a thin rail: the cause in up to three lines, Copy error.",
    },
  },
  defaultArm: "line",
});
