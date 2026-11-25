// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The running tray header's height (SubagentTray.tsx, subagents.css `data-head-height`). Leo,
/// 2026-11-21, on the folded tray over the composer: the redesign is "not terrible" but its proportions
/// are off, "maybe it's too short rn?". The lines under it keep their row height; only the header, the
/// one row the folded tray shows, changes. Compare them in the gallery's
/// `agent-pane.subagent-tray-head-height`.
export const trayHeadHeightLook = defineExperiment({
  id: "subagent-tray-head-height",
  title: "Running tray header height",
  description:
    "How tall the running tray's header row is: the lines' row height, a little taller, or a composer-sized row.",
  arms: {
    row: { label: "Row (28px)", description: "The lines' own row height, as before." },
    roomy: { label: "Roomy (34px)", description: "Six points taller: the marks and counts get air above and below." },
    tall: { label: "Tall (40px)", description: "As tall as the composer's control row: reads as a bar of its own." },
  },
  defaultArm: "roomy",
});

export type TrayHeadHeight = keyof typeof trayHeadHeightLook.arms;
