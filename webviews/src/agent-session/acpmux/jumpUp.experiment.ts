// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// Jump up (jumpUp.ts, VirtualTranscript.tsx `JumpUp`): the button stacked on Jump to latest that goes
/// back to the unread line, the reader's last prompt or where they stopped (#40326). The default is
/// `off`: Jump to latest stands alone, as the Codex app draws it (Lucas, 2026-11-11: two up arrows
/// read as one too many). `on` keeps the pair.
export const jumpUpButton = defineExperiment({
  id: "jump-up",
  title: "Jump up",
  description: "Jump up stacked on Jump to latest, or Jump to latest alone.",
  arms: {
    off: {
      label: "No jump-up arrow",
      description: "No jump-up arrow: Jump to latest stands alone (two up arrows read as one too many).",
    },
    on: {
      label: "Jump pair",
      description: "Jump up stacked on Jump to latest: to the unread line, the last prompt or the last stop (#40326).",
    },
  },
  defaultArm: "off",
});
