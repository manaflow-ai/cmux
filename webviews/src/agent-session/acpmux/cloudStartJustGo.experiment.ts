// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment, experimentArm } from "../../experiments/experiment";

/// Whether a Cloud start blocks the chat or just goes (Leo, 2026-11-25: "playable vs fully
/// installed/downloaded. do we want loading indicators? or just go"). `go`, the default: Return
/// during the start queues the message, which goes with the started chat's first prompt, and a
/// start's spinners show only past 300 ms of a real wait. `hold` is the kill switch: Send waits for
/// the start and spinners show at once, as before.
export const cloudStartJustGo = defineExperiment({
  id: "cloud-start-just-go",
  title: "Cloud start: just go",
  description: "Whether the chat is usable at once while a Cloud chat starts, or waits for it.",
  arms: {
    go: {
      label: "Just go",
      description:
        "Return queues the message for the started chat's first prompt; spinners appear only past 300 ms of a wait.",
    },
    hold: {
      label: "Hold",
      description: "Send waits for the start; spinners show at once (the old behavior, the kill switch).",
    },
  },
  defaultArm: "go",
});

/// The kill switch's read: true unless the `hold` arm is picked.
export function cloudStartGoes(): boolean {
  return experimentArm(cloudStartJustGo) === "go";
}
