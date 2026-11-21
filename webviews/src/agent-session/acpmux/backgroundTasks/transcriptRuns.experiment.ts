// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a subagent's transcript in the Background tasks panel (SubagentTranscript.tsx) draws the work
/// between its replies. Claude Code's drill-in reads as the agent's prose with one quiet line per stretch
/// of work between ("Ran 14 commands, read a file and created a file"), which opens to its steps (Leo,
/// 2026-11-09: "this claude background tasks thing and being able to click into subagents'/helpers' stuff
/// is really good"); ours drew every call and every thought on a line of its own. Compare the arms in
/// the gallery's `agent-pane.background-tasks-runs`. `runs` ships.
export const transcriptRunsLook = defineExperiment({
  id: "background-transcript-runs",
  title: "Background tasks: a subagent's work between replies",
  description:
    "A stretch of tool calls between two replies: one summary line that opens to its steps (Claude Code's), the same with the running stretch open, every stretch folded even one call, or every call on its own line (before).",
  arms: {
    runs: {
      label: "Runs, two calls and up",
      description:
        'Two or more calls between replies fold into one line, "Ran 11 commands, read a file, 2 failed", that opens to each step and thought; a lone call keeps its own line.',
    },
    live: {
      label: "Runs, the running one open",
      description: "As Runs, but the stretch still running stays open, its steps streaming, until it settles.",
    },
    every: {
      label: "Every stretch folded",
      description: 'As Runs, but a lone call folds too: "Ran a command".',
    },
    lines: {
      label: "Every call on its line",
      description: "Before: each tool call and each thought on a line of its own.",
    },
  },
  defaultArm: "runs",
});
