// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Whether a finished Claude turn folds as a whole under one "Worked for". It never does by default
/// (Leo, 2026-11-04: "you can't do it for Claude ... it's just too lossy if you do it for Claude"):
/// its runs and the prose between them stay in sight. The whole-turn fold is the opt-in arm.
/// Compare in `agent-pane.turn-fold-per-harness`.
export const claudeTurnFold = defineExperiment({
  id: "claude-turn-fold",
  title: "Finished Claude turn fold",
  description: "Whether a finished Claude turn keeps its runs in place or folds as a whole under one Worked for.",
  arms: {
    runs: {
      label: "Runs in place",
      description: "No turn-level fold: each run of calls folds into its own line, the prose between them in sight.",
    },
    "worked-for": {
      label: "Worked for (opt-in)",
      description: "One closed Worked for over the conclusion; opened, its runs fold per run.",
    },
  },
  defaultArm: "runs",
});
