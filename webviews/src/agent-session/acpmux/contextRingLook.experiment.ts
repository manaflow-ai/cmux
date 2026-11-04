// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// How the composer's context ring draws the share of the window used, so it always reads as a gauge
/// and never as a loading spinner (Leo, 2026-11-03, reading a 68% ring as a spinner: "and why does it
/// even take time to read settings? you know what things are"). Gallery `agent-pane.context-ring`.
export const contextRingLook = defineExperiment({
  id: "context-ring-look",
  title: "Context ring",
  description:
    "How the 12 px context ring in the composer's quiet row draws the share used. Every arm is static and keeps the ring's hit box.",
  arms: {
    track: {
      label: "Visible track",
      description:
        "The remaining share as a clearly visible track and flat arc ends, so the whole circle reads as one gauge with no gap.",
    },
    arc: {
      label: "Faint track, round ends",
      description:
        "Before: Claude desktop's faint 30% track under a round-ended arc; at about 70% and up it reads as a spinner.",
    },
    percent: {
      label: "Ring + percent",
      description: "The faint ring with the percent used as a caption beside it.",
    },
    "fill-quiet": {
      label: "Thick quiet fill",
      description: "A thicker track with flat ends, the used share in the text colour at reduced alpha.",
    },
  },
  defaultArm: "track",
});
