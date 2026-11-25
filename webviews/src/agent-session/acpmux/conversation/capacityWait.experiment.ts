// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a turn acpmux holds for capacity draws in the transcript (RFD model-overload-smoothing §3.8;
/// Leo, 2026-11-24: "fix 529s properly with better designs"). Every arm is calm, with no red and
/// no raw error in the body; `off` keeps the failed turn's card as before.
export const capacityWaitLook = defineExperiment({
  id: "capacity-wait",
  title: "Capacity wait",
  description: "How a turn waiting for model capacity draws: one calm state with a countdown, the error under Details.",
  arms: {
    line: {
      label: "Quiet line",
      description:
        "One muted line where the answer would be: a turning ring, Waiting for capacity, about 40s, Details.",
    },
    card: {
      label: "Calm card",
      description:
        "A neutral card: an hourglass, Waiting for capacity, the countdown and that the chat goes on by itself.",
    },
    bar: {
      label: "Draining bar",
      description: "The quiet line over a thin bar that fills toward the resume time.",
    },
    off: {
      label: "Off (failed card)",
      description: "As before: the failed turn's card with its cause and Retry.",
    },
  },
  defaultArm: "line",
});
