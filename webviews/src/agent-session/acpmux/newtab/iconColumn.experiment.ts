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
    current: {
      label: "Current",
      description: "The strip and the quiet row as they were: each places its own icon from its own padding.",
    },
    "chip-to-shield": {
      label: "Chip to shield",
      description: "Only the folder chip moves: its icon takes the shield's inset; + and the shield stay.",
    },
    "plus-center": {
      label: "+ center",
      description: "The folder icon and the shield both move onto the + glyph's center.",
    },
    shared: {
      label: "Shared column",
      description:
        "One --nt-icon-column token (the + button's center) that the strip, the box and the quiet row all place their first icon on.",
    },
  },
  defaultArm: "current",
});

export type NewTabIconColumnArm = keyof typeof newTabIconColumn.arms;

export const newTabIconColumnArm = (): NewTabIconColumnArm => experimentArm(newTabIconColumn);
