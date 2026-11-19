// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Session replay (ReplayScreen.tsx): on (Leo, 2026-11-19, approving it: "all of them"). It changes no
/// default look: the chat menu and View menu offer Replay, and the replay draws only once opened. Turn
/// it off by setting `cmux.experiments` to `{"session-replay":"off"}` in the pane's web inspector.
export const sessionReplay = defineExperiment({
  id: "session-replay",
  title: "Session replay",
  description:
    "The chat menu and View menu offer Replay: the chat's recorded history plays back read-only at 10×, beside the files and commands it touched.",
  arms: {
    off: { label: "Off", description: "No Replay item." },
    on: { label: "On", description: "The chat menu's Replay plays the chat back." },
  },
  defaultArm: "on",
});
