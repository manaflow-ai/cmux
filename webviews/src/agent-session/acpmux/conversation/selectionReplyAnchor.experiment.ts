// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Where the selection's Reply chip first goes, relative to the selection's last glyph (Leo,
/// 2026-11-11, on the chip drawn at the far end of the next line: "this reply is in the wrong spot").
/// Every arm keeps the chip in the transcript column and the visible transcript; where its spot does
/// not fit, each falls back to the same order (selectionReplyPlace). Compare them in the gallery's
/// `agent-pane.selection-reply` (SelectionReply.tsx).
export const selectionReplyAnchor = defineExperiment({
  id: "selection-reply-anchor",
  title: "Selection Reply chip anchor",
  description: "Where the Reply chip goes next to the selection's last character: after it, over it or under its line.",
  arms: {
    after: {
      label: "After the last character",
      description:
        "On the selection's last line, just after its last character; flipped over its own last words at the column's edge.",
    },
    over: {
      label: "Over the last character",
      description: "Centred over the selection's last character, on the line above it.",
    },
    under: {
      label: "Under the last line",
      description: "Centred under the selection's last character, on the line below it.",
    },
  },
  defaultArm: "after",
});
