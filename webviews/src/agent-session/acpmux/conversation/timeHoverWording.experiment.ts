// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a transcript time's hover reads once a time the message pointed ahead to has passed (Leo,
/// 2026-11-07, on "08:36Z" in a message sent at 08:21Z hovering as "24 hr ago": "It's too biased
/// towards the past here."). While the time is still ahead every arm says "in 15 min"; a time
/// before its message always says "15 min ago". Compare the arms in `agent-pane.time-hover`.
export const timeHoverWording = defineExperiment({
  id: "time-hover-wording",
  title: "Transcript time hover, after a future time passes",
  description:
    "What a time the message pointed ahead to says once it has passed: relative to the message, to now, or both.",
  arms: {
    message: {
      label: "After this message",
      description: '"12:36 AM PST, 15 min after this message": fixed, and it says the message meant it as ahead.',
    },
    now: {
      label: "Ago",
      description: '"12:36 AM PST, 3 hr ago": the age at reading time, the same as any past time.',
    },
    both: {
      label: "Ago, after this message",
      description: '"12:36 AM PST, 3 hr ago, 15 min after this message": both clocks.',
    },
  },
  defaultArm: "message",
});
