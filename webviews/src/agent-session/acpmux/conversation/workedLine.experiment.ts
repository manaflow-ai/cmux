// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What a finished turn's closed "Worked for" line says besides its time. The glance shows the
/// outcome, not the steps: the line is the transcript's one look at past work, and today it spends
/// it on a duration. The arms name what the turn did, from the calls the fold already holds (no
/// model call; one pass over the turn's calls). Compare in `agent-pane.worked-line`.
/// `time` ships: a closed Worked for reads "Worked for 36s" alone, its counts inside the fold on the
/// run lines (Leo, 2026-11-07, ask-db01e91a83: "inside the worked for, then you wouldn't need to have,
/// like, the top-level finished two and ran eight"; 2026-11-25, on "23s · Ran 2 commands": "did we
/// remove these yet"). `outcome` shipped once in #49934 and brought the counts back; it stays an arm.
/// workedForTimeOnly.test.tsx holds the default to the time alone.
export const workedLine = defineExperiment({
  id: "worked-line",
  title: "What a closed Worked for says",
  description:
    "Whether a finished turn's Worked for line names only its time, or also what it did and how it came out.",
  arms: {
    time: {
      label: "Time only",
      description: "Worked for 36s: the time alone, the earlier line.",
    },
    counts: {
      label: "Counts",
      description: "Worked for 36s · 4 commands · 2 files: what it touched, as counts.",
    },
    outcome: {
      label: "Counts and outcome",
      description:
        "Worked for 36s · Edited 2 files and ran 4 commands · tests passed · opened PR #482; failures in the failure red.",
    },
    sentence: {
      label: "One sentence",
      description: "Edited a file and ran 2 commands: 1 failed, tests failed · 36s; the outcome first, the time last.",
    },
  },
  defaultArm: "time",
});
