// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Where a running turn's clock stands (turns.ts `shapeLiveTurn`). The Codex app and T3 Code draw
/// "Working for 32s" over the turn's work, under the prompt, where "Worked for" lands when the turn
/// ends, and the line at the bottom reads only what the agent does now, "Thinking" (Lucas,
/// 2026-11-11). Before, the clock stood on that bottom line and nothing drew over the work (Leo,
/// 2026-10-21).
export const liveTurnClock = defineExperiment({
  id: "live-turn-clock",
  title: "Live turn clock",
  description: "The running turn's clock: Working for over the work, or on the live line at the bottom.",
  arms: {
    top: {
      label: "Working for on top",
      description:
        '"Working for 32s" under the prompt, where Worked for lands; the bottom line says only "Thinking", as the Codex app does.',
    },
    line: {
      label: "On the live line",
      description: '"Thinking 18s" at the bottom; nothing over the work.',
    },
  },
  defaultArm: "top",
});
