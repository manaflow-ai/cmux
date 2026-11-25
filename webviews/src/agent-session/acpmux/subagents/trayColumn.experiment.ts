// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Where the composer hat's leading column starts (SubagentTray.tsx `data-column`, subagents.css
/// `--acpmux-tray-inset-start`). Lucas raised it, and Leo, 2026-11-24 00:18Z, on the hat's mark and
/// count over the composer: "for one at least now the alignment becomes... maybe awkward? against the
/// (currently fixing, ignore the outline) attachment + button. lucas raised that". The hat's marks sat
/// on the + chip's outer edge (the composer's 8px inset) while the + glyph's ink starts 6px further in,
/// so the two leading columns read as off by a few pixels. The trailing side keeps the composer's
/// inset either way, so the chevron stays over Send's column. Compare them in the gallery's
/// `agent-pane.composer-hat-groups`.
export const trayColumnLook = defineExperiment({
  id: "subagent-tray-column",
  title: "Composer hat leading column",
  description: "Where the composer hat's marks and lines start: on the + glyph's ink, or on the + chip's edge.",
  arms: {
    glyph: {
      label: "On the + glyph",
      description: "The hat's marks start where the + glyph's ink does, one column with the composer's + and its text.",
    },
    chip: {
      label: "On the + chip's edge",
      description: "The composer's inset, as before: the marks start at the + chip's outer edge.",
    },
  },
  defaultArm: "glyph",
});

export type TrayColumn = keyof typeof trayColumnLook.arms;
