// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Where the selection's Reply chip goes when it has no room on the selection's last line (Leo,
/// 2026-11-07: "if it's ever on the right edge, just make it in line"). Every arm keeps the chip
/// in the transcript column, never in the margin; they differ only in where the wrapped chip
/// sits. Compare them in the gallery's `agent-pane.selection-reply` (SelectionReply.tsx).
export const selectionReplyWrap = defineExperiment({
  id: "selection-reply-wrap",
  title: "Selection Reply chip wrap",
  description:
    "Where the Reply chip goes when the selection ends too close to the column's right edge for it to fit on that line.",
  arms: {
    "line-start": {
      label: "Next line start",
      description: "Wraps like the next word would: to the start of the line under the selection's end.",
    },
    "under-end": {
      label: "Under the end",
      description: "Right under the selection's last character, its right edge on it.",
    },
    edge: {
      label: "At the edge",
      description: "Stays on the selection's last line, pinned to the column's right edge over the last words.",
    },
  },
  defaultArm: "line-start",
});
