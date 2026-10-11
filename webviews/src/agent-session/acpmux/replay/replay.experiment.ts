// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Session replay (ReplayScreen.tsx): off until its look is part of the pane. Dogfood: set
/// `cmux.experiments` to `{"session-replay":"on"}` in the pane's web inspector and reload.
export const sessionReplay = defineExperiment({
  id: "session-replay",
  title: "Session replay",
  description: "The chat menu offers Replay: the chat's recorded history plays back read-only, as it happened.",
  arms: {
    off: { label: "Off", description: "No Replay item." },
    on: { label: "On", description: "The chat menu's Replay plays the chat back." },
  },
  defaultArm: "off",
});
