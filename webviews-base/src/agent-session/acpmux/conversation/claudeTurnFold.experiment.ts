// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Whether a finished Claude turn folds as a whole under one "Worked for". It does by default, for
/// Codex parity on every model (Lucas, 2026-11-06). The `runs` arm keeps the older in-place look (Leo,
/// 2026-11-04: "you can't do it for Claude ... it's just too lossy if you do it for Claude"): its runs
/// and the prose between them stay in sight.
/// Compare in `agent-pane.turn-fold-per-harness`.
export const claudeTurnFold = defineExperiment({
  id: "claude-turn-fold",
  title: "Finished Claude turn fold",
  description: "Whether a finished Claude turn keeps its runs in place or folds as a whole under one Worked for.",
  arms: {
    runs: {
      label: "Runs in place (older)",
      description: "No turn-level fold: each run of calls folds into its own line, the prose between them in sight.",
    },
    "worked-for": {
      label: "Worked for",
      description: "One closed Worked for over the conclusion; opened, its runs fold per run.",
    },
  },
  defaultArm: "worked-for",
});
