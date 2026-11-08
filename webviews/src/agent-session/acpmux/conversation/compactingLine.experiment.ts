// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the running turn's live line (Thinking.tsx) reads while the agent compacts the conversation.
/// Each arm folds the transcript's "Compacting the conversation…" row into the line and drops
/// "Thinking" and the token count (Leo, 2026-11-07: "You're not thinking during this time ... That
/// should replace the thinking area"); they differ in the clock. Compare them in the gallery's
/// `agent-pane.live-line-compacting`.
export const compactingLine = defineExperiment({
  id: "compacting-line",
  title: "Compacting live line",
  description: "The live line while the conversation compacts: its own clock, its clock and the turn's, or no clock.",
  arms: {
    own: {
      label: "Own clock",
      description: '"Compacting conversation… 12s": shimmering, timed from the compaction\'s start.',
    },
    turn: {
      label: "Own and turn clock",
      description: "\"Compacting conversation… 12s · 1m 35s\": the compaction's time, then the turn's.",
    },
    calm: {
      label: "Calm",
      description: '"Compacting conversation…": no clock and no shimmer, as the retry line reads.',
    },
  },
  defaultArm: "own",
});
