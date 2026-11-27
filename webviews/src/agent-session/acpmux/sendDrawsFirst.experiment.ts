// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment, experimentArm } from "../../experiments/experiment";

/// Whether a sent prompt's bubble draws before the asks a Cloud chat makes ahead of the prompt (the
/// app opening its hand-off turn, `cloud.handoffTurn`, up to TURN_WAIT_MS, and a handoff read), or
/// after them (Leo, 2026-11-25: "when you press enter, the stuff should just start playing. we dont
/// need to wait/get blocked by anything on rendering"). `first`, the default: the bubble draws in the
/// Enter's frame and the send draws over it under the same row id. `after` is the kill switch: the
/// bubble waits for those asks, as before.
export const sendDrawsFirst = defineExperiment({
  id: "send-draws-first",
  title: "Send: bubble before the Cloud asks",
  description: "Whether a Cloud chat's sent bubble draws in the Enter's frame or after its hand-off turn ask.",
  arms: {
    first: {
      label: "Draw first",
      description: "The bubble draws in the Enter's frame; the hand-off turn ask runs behind it.",
    },
    after: {
      label: "After the asks",
      description: "The bubble draws once the hand-off turn ask answers (the old behavior, the kill switch).",
    },
  },
  defaultArm: "first",
});

/// The kill switch's read: true unless the `after` arm is picked.
export function sendDrawsBeforeAsks(): boolean {
  return experimentArm(sendDrawsFirst) === "first";
}
