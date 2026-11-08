// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What the selection's Reply chip does when no spot near the selection's end is free of other
/// text: a selection that ends at a line's right edge mid-paragraph, or mid-line with text all
/// around (Leo, 2026-11-07: "if it's ever on the right edge, just make it in line"). Every arm keeps
/// the chip in the transcript column and the visible transcript, and off every word the person did
/// not select. Compare them in the gallery's `agent-pane.selection-reply` (SelectionReply.tsx).
export const selectionReplyWrap = defineExperiment({
  id: "selection-reply-wrap",
  title: "Selection Reply chip with no free spot",
  description:
    "Where the Reply chip goes when the spots over, after and under the selection's end all hold other text.",
  arms: {
    "own-end": {
      label: "Over its last words",
      description: "On the selection's last line, over its own last words, its right edge at the selection's end.",
    },
    "own-start": {
      label: "Over its last line's start",
      description: "On the selection's last line, over its own words from that line's start.",
    },
    farther: {
      label: "Farther gap",
      description: "Up to three lines over or under the end for a spot with no text, before covering the selection.",
    },
  },
  defaultArm: "own-end",
});
