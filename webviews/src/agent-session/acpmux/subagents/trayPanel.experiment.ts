// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the tray of running work (SubagentTray.tsx) holds a long list under its pinned header (Leo
/// 2026-10-25: "this section, the whatever background tasks, that sort of area, it's kind of wack").
/// Every arm keeps the header pinned at the top and View all pinned at the foot; they differ in how
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
      description: "Header and View all pinned; the list between them shows five lines, then scrolls.",
    },
    tall: {
      label: "Eight lines",
      description: "Header and View all pinned; the list shows eight lines before it scrolls.",
    },
    sectioned: {
      label: "Ended set apart",
      description: "Five lines; a hairline splits what runs from what ended, and ended lines are dim.",
    },
  },
  defaultArm: "pinned",
});
