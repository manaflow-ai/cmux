// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Where a reply table's Open and Copy sit (Leo 2026-11-05: "idk why the expand/copy buttons are
/// soooo far away"). Every arm attaches them to the table's own box, so they move with it and
/// never drift to the column's far edge; the arms differ only in where on that box. Compare them
/// in the gallery's `agent-pane.table-block`.
export const tableActionsPlace = defineExperiment({
  id: "table-actions-place",
  title: "Reply table actions",
  description:
    "Where a reply table's Open and Copy sit on hover: in its top-right corner, above it, or just beside it.",
  arms: {
    corner: {
      label: "In the corner",
      description:
        "Bare buttons inside the table's top-right corner, on the header row, which keeps room for them (no pill, as a code card's corner).",
    },
    above: {
      label: "Above",
      description: "A small glass pill that rises just above the table's top-right corner, over the line before it.",
    },
    beside: {
      label: "Beside",
      description: "Plain icon buttons just past the table's right edge, as before, now next to the table itself.",
    },
  },
  defaultArm: "corner",
});
