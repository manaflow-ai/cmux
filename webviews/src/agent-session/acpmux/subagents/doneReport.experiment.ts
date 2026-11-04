// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What a finished subagent's line (SubagentDoneLine.tsx) offers of its final report. Leo,
/// 2026-11-03, on parallel agents in the running tray: "Tray only, richer". The quiet "Subagent
/// finished" line stays; its report is one click away under it, and the line itself still opens the
/// agent's own view. Compare the arms in the gallery's `agent-pane.subagent-done`.
export const doneReportLook = defineExperiment({
  id: "subagent-done-report",
  title: "Subagent finished: its final report",
  description:
    "A finished subagent's line and its final report: a chevron after the words opens it under the line, its first two lines always shown with Show more, or the line only opens the agent's view.",
  arms: {
    disclosure: {
      label: "Chevron opens report",
      description: "A chevron right after the line's words opens the report under the line; the line opens the view.",
    },
    preview: {
      label: "Two-line preview",
      description: "The report's first two lines always under the line, with Show more; the line opens the view.",
    },
    view: {
      label: "Before",
      description: "As it was: the line only opens the agent's view, the report is there.",
    },
  },
  defaultArm: "disclosure",
});

export type DoneReportLook = keyof typeof doneReportLook.arms;
