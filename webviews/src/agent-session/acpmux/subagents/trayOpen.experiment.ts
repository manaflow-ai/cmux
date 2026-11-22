// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the running tray's header opens the Background tasks panel (SubagentTray.tsx,
/// backgroundTasks/BackgroundTasksPanel.tsx). Leo, 2026-11-03, on Claude's "9 background commands
/// completed, 3 running ›" chip beside its Background tasks panel: "i feel like having a thing like
/// this that can either expand OR open up to this sort of thing would be quite cool". Compare the arms
/// in the gallery's `agent-pane.subagent-tray-open`.
export const trayOpenLook = defineExperiment({
  id: "subagent-tray-open",
  title: "Running tray opens Background tasks",
  description:
    "How the running tray's header reaches the full Background tasks panel: a panel button beside its chevron, the whole header, or not at all.",
  arms: {
    button: {
      label: "Panel button",
      description:
        "The header still expands in place; a panel button in the Stop column, right before its chevron, opens Background tasks.",
    },
    header: {
      label: "Whole header",
      description:
        "Claude's chip: a click anywhere on the header opens Background tasks; the tray no longer expands in place.",
    },
    none: {
      label: "None",
      description: "The header only expands in place, as before; the chat's ⋯ menu opens Background tasks.",
    },
  },
  defaultArm: "button",
});
