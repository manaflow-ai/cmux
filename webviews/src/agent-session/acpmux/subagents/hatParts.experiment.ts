// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a finished line ends (AgentLine.tsx trail, and a lone finished item's hat header). Leo,
/// 2026-11-07: "I still just, like, I just feel like there's something off about this, like, the done
/// whatever minutes type thing ... I know that the thing is aligned, but it just doesn't look that...
/// Great." Compare them in the gallery's `agent-pane.composer-hat-done`.
export const hatDoneLook = defineExperiment({
  id: "composer-hat-done",
  title: "Composer hat: a finished line's end",
  description:
    "A finished line's state and time: a check mark and the time, the words Done and the time, Done in the success colour, or the time alone.",
  arms: {
    check: {
      label: "Check and time",
      description:
        "A small check in the success colour, then the total in tabular figures; the word Done is for screen readers.",
    },
    words: {
      label: "Done · time",
      description: "As before: the muted word Done, a dot, the time.",
    },
    accent: {
      label: "Done in colour",
      description: "The word Done in the success colour at medium weight, then the time, muted and tabular.",
    },
    time: {
      label: "Time alone",
      description: "Only the total, muted and tabular; the word Done is for screen readers.",
    },
  },
  defaultArm: "check",
});
