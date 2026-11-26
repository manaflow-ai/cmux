// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment, experimentArm } from "../../experiments/experiment";

/// Whether a wait's spinner (resuming, connecting, a fork or rewind in flight, a catalog refresh)
/// shows at once or only past 300 ms (Leo, 2026-11-25: "there are all manner of tips and tricks to
/// make it feel so much better than it is"). A wait that ends inside 300 ms then draws no spinner
/// for a frame or two. `at-once`, the default, keeps today's look; `delayed` is the trick.
export const waitSpinnerDelay = defineExperiment({
  id: "wait-spinner-delay",
  title: "Wait spinners: only past 300 ms",
  description: "Whether a short wait flashes its spinner, or shows nothing new until 300 ms pass.",
  arms: {
    "at-once": {
      label: "At once",
      description: "A wait's spinner shows on its first frame (the current behavior).",
    },
    delayed: {
      label: "Past 300 ms",
      description:
        "A wait's spinner shows only once the wait runs past 300 ms; until then the control keeps its own icon.",
    },
  },
  defaultArm: "at-once",
});

/// How long a wait spinner holds off: 300 ms on the `delayed` arm, 0 (at once) otherwise.
export function waitSpinnerDelayMs(): number {
  return experimentArm(waitSpinnerDelay) === "delayed" ? 300 : 0;
}
