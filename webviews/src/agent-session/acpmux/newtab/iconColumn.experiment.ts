// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment, experimentArm } from "../../../experiments/experiment";

/// The New Tab composer's icon column (Leo 2026-11-07: the projects and their icons "should be sort
/// of like center aligned with the bypass permissions symbols"): the folder chip's icon over the box,
/// the + glyph in it and the permission mode's shield under it on one vertical center line. Every arm
/// keeps that line; the arms differ in what carries the chips around it, so they read apart at a
/// glance (Leo 2026-11-15, shown four arms about a pixel apart: "those all look the same to me").
/// Compare the arms in the gallery (agent-pane.new-tab-icon-column); test/newtab-icon-column.test.ts
/// measures each arm's three centers. The arms' looks are newtab/screen.css's `data-icon-column` rules.
export const newTabIconColumn = defineExperiment({
  id: "new-tab-icon-column",
  title: "New Tab icon column",
  description:
    "What carries the folder, machine and permission chips on the icon column: bare text, a tray, capsules or glyphs alone.",
  arms: {
    pad: {
      label: "Bare text",
      description:
        "The chips are muted text over and under the box with no fill; the icon column is the only structure (shipped).",
    },
    tray: {
      label: "Tray",
      description:
        "The folder and machine chips sit in a filled tray tucked under the box's top edge, as Codex's desktop composer.",
    },
    pills: {
      label: "Capsules",
      description:
        "Every chip over and under the box is its own filled capsule (the button corner) with a hairline rim.",
    },
    icons: {
      label: "Glyphs only",
      description:
        "The chips drop their names and chevrons: a bare column of glyphs (folder, +, shield); the names stay in the accessible name.",
    },
  },
  defaultArm: "pad",
});

export type NewTabIconColumnArm = keyof typeof newTabIconColumn.arms;

export const newTabIconColumnArm = (): NewTabIconColumnArm => experimentArm(newTabIconColumn);
