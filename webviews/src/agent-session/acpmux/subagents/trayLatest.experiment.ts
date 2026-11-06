// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Where a running tray line says what its agent did last (AgentLine.tsx `latest`, trayDetail.ts
/// `latestLine`). Leo, 2026-11-03, watching Claude Code Desktop run background agents in parallel:
/// "yo wtf i want this kind of feature in cmux-next too", then, on keeping them in the tray: "Tray
/// only, richer". Then, 2026-11-04, on the two-row lines: "I don't like how misaligned and how much
/// extra space those agent cards take compared to the past one lines we had/how Claude code just has
/// one lines too": the latest step follows the title on the line's one row (`inline`, the default).
/// Compare the arms in the gallery's `agent-pane.parallel-agents`.
export const trayLatestLook = defineExperiment({
  id: "subagent-tray-latest",
  title: "Running tray: each agent's latest line",
  description:
    "Where a running agent's line in the tray says what it did last: on a quiet second line under its title, dim after the title on the same line, or only in the tooltip.",
  arms: {
    inline: {
      label: "After the title",
      description: "One row: muted after the title, cut to the room left before the state, time and Stop columns.",
    },
    below: {
      label: "Second line",
      description: "A muted second line under the title, cut to one line: each line is two rows tall.",
    },
    tooltip: {
      label: "Tooltip only",
      description: "As before: the line shows its title, state and time; its latest step is in the tooltip.",
    },
  },
  defaultArm: "inline",
});
