// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the Background tasks panel (BackgroundTasksPanel.tsx) lists an agent's tasks. Compare the arms
/// in the gallery's `agent-pane.background-tasks`. `nested` is Claude Desktop's shape, the one Leo
/// pointed at (2026-10-29: "i like these tasks"), and ships.
export const backgroundTasksLook = defineExperiment({
  id: "background-tasks-panel",
  title: "Background tasks panel",
  description:
    "An agent's tasks: under a counts line that opens them (Claude Desktop's), listed flat under the agent, or opened from counts on the agent's own line.",
  arms: {
    nested: {
      label: "Counts line",
      description:
        'The agent\'s line, then "24 tasks, 3 failed" which opens its tasks: running first, then N finished, folded.',
    },
    flat: {
      label: "Flat",
      description: "Every agent's tasks listed under it, running then finished, with no counts line to open.",
    },
    compact: {
      label: "Counts on the agent",
      description: "One line per agent with its counts on the right; the counts open its tasks.",
    },
  },
  defaultArm: "nested",
});
