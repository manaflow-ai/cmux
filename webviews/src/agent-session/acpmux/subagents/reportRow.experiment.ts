// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a subagent's report to its chat draws in the transcript (Leo, 2026-11-05, on a clock-icon
/// line reading the report's first words under "Subagent finished": "what's up with this \"tool
/// call\"?"). The report is the task notification Claude Code hands the chat when a subagent ends;
/// it started a background turn, whose line said the notification's summary as if it were a tool
/// call. The arms name it as the subagent's report under that subagent's "Subagent finished" line;
/// open, it reads as a reply does. Compare them in the gallery's `agent-pane.subagent-report`.
export const reportRowLook = defineExperiment({
  id: "subagent-report-row",
  title: "Subagent report row",
  description:
    "A subagent's report to its chat: a 'Report from' line under its 'Subagent finished' line, set on the text column or on a rule, or the clock line it was.",
  arms: {
    nested: {
      label: "Under the line",
      description:
        "'Report from <name>' under the finished line, on its text column, no icon; open, the report in the reply's Markdown.",
    },
    rule: {
      label: "On a rule",
      description: "As Under the line, with a thin rule down its left edge that holds the opened report too.",
    },
    before: {
      label: "Before",
      description: "As it was: a clock and the notification's first words, a tool-row line.",
    },
  },
  defaultArm: "nested",
});

export type ReportRowLook = keyof typeof reportRowLook.arms;
