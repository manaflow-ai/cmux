// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment, experimentArm } from "../../../experiments/experiment";

/// The New Tab composer's icon column (Leo 2026-11-07: the projects and their icons "should be sort
/// of like center aligned with the bypass permissions symbols"): the folder chip's icon over the box,
/// the + glyph in it and the permission mode's shield under it on one vertical center line. Compare
/// the arms in the gallery (agent-pane.new-tab-icon-column); test/newtab-icon-column.test.ts
/// measures each arm's three centers.
export const newTabIconColumn = defineExperiment({
  id: "new-tab-icon-column",
  title: "New Tab icon column",
  description: "Where the folder chip's icon, the + glyph and the permission shield line up.",
  arms: {
    pad: {
      label: "Derived padding",
      description:
        "The project badge's leading padding is the ghost icon's center less half the badge: the badge centers on the icon column, the hover pill keeps its edge.",
    },
    shift: {
      label: "Shift the chip",
      description:
        "The chip keeps its full inset and moves out by the badge's extra half width; its hover pill moves with it.",
    },
    shrink: {
      label: "Shrink the badge",
      description: "The project badge draws at the 14 px ghost icon's size, so the button's icon padding centers it.",
    },
    current: {
      label: "Before",
      description: "The ghost button's full inset before the badge: its center 4.5 px right of + and the shield.",
    },
  },
  defaultArm: "pad",
});

export type NewTabIconColumnArm = keyof typeof newTabIconColumn.arms;

export const newTabIconColumnArm = (): NewTabIconColumnArm => experimentArm(newTabIconColumn);
