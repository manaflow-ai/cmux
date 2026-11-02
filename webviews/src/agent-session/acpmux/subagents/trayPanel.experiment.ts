// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the tray of running work (SubagentTray.tsx) holds a long list under its pinned header (Leo
/// 2026-10-25: "this section, the whatever background tasks, that sort of area, it's kind of wack").
/// Every arm keeps the header pinned at the top, with every line in the list; they differ in how
/// many lines show before the list scrolls and in how what ended reads. Compare them in the
/// gallery's `agent-pane.subagent-tray`.
export const trayPanelLook = defineExperiment({
  id: "subagent-tray-panel",
  title: "Subagent tray panel",
  description:
    "The tray's list under its pinned header: five lines then scroll, eight lines then scroll, or five lines with what ended set apart and dimmed.",
  arms: {
    pinned: {
      label: "Five lines",
      description: "Header pinned; the list under it shows five lines, then scrolls.",
    },
    tall: {
      label: "Eight lines",
      description: "Header pinned; the list shows eight lines before it scrolls.",
    },
    sectioned: {
      label: "Ended set apart",
      description: "Five lines; a hairline splits what runs from what ended, and ended lines are dim.",
    },
  },
  defaultArm: "pinned",
});

/// Where a tray line's spent work (tokens, tool uses, a workflow's agents) sits beside its one
/// glyph, its title and its time (Leo 2026-10-31: "why is this still so ass in latest nightly"; the
/// running row read its stats on a second line under a kind subtitle). Every arm draws one leading
/// glyph, no agent-type subtitle and no Done or Running word; they differ in the stats' place and in
/// whether the time keeps its column. Compare them in the gallery's `agent-pane.subagent-tray`
/// (`row-anatomy`).
export const trayRowLook = defineExperiment({
  id: "subagent-tray-row",
  title: "Subagent tray row",
  description:
    "A tray line's stats: muted in the trailing meta before the time, on a second line under the title, or right after the title with the time beside them.",
  arms: {
    trailing: {
      label: "Trailing meta",
      description: "One line: glyph, title, then the muted stats and time at the trailing edge, lined up across lines.",
    },
    below: {
      label: "Second line",
      description: "The stats on a second muted line under the title; the time keeps the trailing column.",
    },
    inline: {
      label: "After the title",
      description: "One line: the stats and the time follow the title, muted, with no trailing column.",
    },
  },
  defaultArm: "trailing",
});
