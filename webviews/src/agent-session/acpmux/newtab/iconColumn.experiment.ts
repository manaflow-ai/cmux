// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment, experimentArm } from "../../../experiments/experiment";

/// The New Tab composer's icon column (Leo 2026-11-07: the projects and their icons "should be sort
/// of like center aligned with the bypass permissions symbols"): the folder chip's icon over the box,
/// the + glyph in it and the permission mode's shield under it on one vertical center line. Every arm
/// keeps that line; the arms differ in what carries the chips around it, so they read apart at a
/// glance (Leo 2026-11-15, shown four arms about a pixel apart: "those all look the same to me").
/// Compare the arms in the gallery (agent-pane.new-tab-icon-column); test/newtab-icon-column.test.ts
/// measures each arm's three centers. tiles, appicon and dock change the glyphs' treatment (Leo
/// 2026-11-15: "theese are kinda crappy looking icons and stuff"): a tile around each glyph's own
/// box. tiles ships (the blind pick of 2026-11-15; appicon's accent folder breaks the one chip ink
/// rule, newtab-chip-ink-edges.test.ts). The arms' looks are newtab/screen.css's `data-icon-column` rules.
export const newTabIconColumn = defineExperiment({
  id: "new-tab-icon-column",
  title: "New Tab icon column",
  description:
    "What carries the folder, machine and permission chips on the icon column: bare text, a tray, capsules or glyphs alone.",
  arms: {
    pad: {
      label: "Bare text",
      description:
        "The chips are muted text over and under the box with no fill; the icon column is the only structure (shipped until the Tiles pick).",
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
    tiles: {
      label: "Tiles",
      description:
        "Icon treatment: the folder, machine, + and shield glyphs sit on soft square tiles in the chip's ink, as a system settings sidebar; the names stay.",
    },
    appicon: {
      label: "App icons",
      description:
        "Icon treatment: app-icon squircles. The folder is the hero on the accent's tile, the rest on neutral tiles, + on a round one; the project name is emphasized.",
    },
    dock: {
      label: "Dock",
      description:
        "Icon treatment: icons only, on larger tiles, a dock-like column; the names stay in the accessible name.",
    },
  },
  defaultArm: "tiles",
});

export type NewTabIconColumnArm = keyof typeof newTabIconColumn.arms;

export const newTabIconColumnArm = (): NewTabIconColumnArm => experimentArm(newTabIconColumn);
