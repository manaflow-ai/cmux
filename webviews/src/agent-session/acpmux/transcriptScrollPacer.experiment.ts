// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// How native transcript scroll events commit virtualized rows. The frame arm is the shipped path,
/// which keeps React work to one commit per display frame. The synchronous arm is an opt-in comparison
/// for the UI performance baseline's transcript-fling row (24 ms p50 / 33 ms p95, target 10 ms).
export const transcriptScrollPacer = defineExperiment({
  id: "transcript-scroll-pacer",
  title: "Transcript scroll pacing",
  description:
    "Scroll a long transcript and compare one virtualized-row commit per display frame with a synchronous commit for every native scroll event.",
  arms: {
    frame: {
      label: "One commit per frame",
      description: "Coalesce native scroll events and commit the latest offset once per display frame.",
    },
    sync: {
      label: "Synchronous commits",
      description: "Commit each native scroll event immediately to compare scroll response and frame cost.",
    },
  },
  defaultArm: "frame",
});
