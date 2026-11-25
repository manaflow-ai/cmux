// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the running turn's live line (Thinking.tsx) says its two times past the turn's first step:
/// the finished step's own time (or the turn's summed thinking) and the turn's clock. They read as
/// two bare durations, "python3 - <<'EOF' 3s · 21s · 549 tokens", with nothing saying which is
/// which (Leo's capture, 2026-11-07). Compare them in the gallery's `agent-pane.live-line-times`.
export const liveLineTimes = defineExperiment({
  id: "live-line-times",
  title: "Live line times",
  description:
    "The live line's step time and turn clock: labelled, the turn's clock alone, or the step's with the turn's on hover.",
  arms: {
    labelled: {
      label: "Labelled",
      description: '"step 3s · turn 21s": both times, each named.',
    },
    turn: {
      label: "Turn only",
      description: '"21s": the turn\'s clock alone; a long turn reads as that long a think again.',
    },
    hover: {
      label: "Step, turn on hover",
      description: "\"3s\": the step's own time; the turn's clock only in its tooltip, so nothing on the line ticks.",
    },
  },
  // One clock, as the Codex app's live line has (Lucas, 2026-11-11, on "Thinking 372ms · turn 5s").
  defaultArm: "turn",
});
