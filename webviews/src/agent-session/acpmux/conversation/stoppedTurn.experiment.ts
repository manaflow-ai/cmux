// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a stopped turn says it stopped (Leo, 2026-11-03, on "The agent didn't answer Stop, so cmux
/// ended its turn." under a Continue button: "this is an "interesting" recovery flow... idk if it
/// should be showing things like that"). A Stop acpmux had to force reads as any other Stop; only the
/// footer's tooltips say cmux ended it. Compare the arms in the gallery's `agent-pane.stopped-turn`.
export const stoppedTurnLook = defineExperiment({
  id: "stopped-turn-look",
  title: "Stopped turn",
  description: "How a stopped turn's footer says it stopped, whoever ended it.",
  arms: {
    word: {
      label: "Stopped, then Continue",
      description: "A muted Stopped after the footer's buttons, then Continue on the last turn.",
    },
    trailing: {
      label: "Continue, then Stopped",
      description: "Continue first, the muted Stopped after it, before the time.",
    },
    none: {
      label: "Continue only",
      description: "No word: the footer's buttons and Continue, as a stop drew before; Stopped is in the tooltip.",
    },
  },
  defaultArm: "word",
});
