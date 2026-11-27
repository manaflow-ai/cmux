// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What the one-line hat's marks do as the bar narrows (deckFit.ts). Leo, 2026-11-27, on "10 subagents
/// working" then eight icons and "+N more": "hm should we compact these and drop them away in favour
/// of text when things shrink?" / "this is just an awkward looking layout". Compare them in the
/// gallery's `agent-pane.composer-hat-line-deck`, at its widths.
export const deckFitLook = defineExperiment({
  id: "composer-hat-deck-fit",
  title: "Composer hat: the marks as the bar narrows",
  description:
    "How the one-line hat's row of marks gives way to width: it never changes (before), it overlaps into a stack and stays at every width (stack), or it steps down by width (steps).",
  arms: {
    steps: {
      label: "Steps down, then words",
      description:
        "Wide: eight marks and '+N more'. Narrower: five marks overlapped and '+N', then three, then no marks, the sentence alone. Measured too: when the words would truncate or the panel button's end is pushed out, it takes the next step.",
    },
    stack: {
      label: "Always a stack",
      description: "Up to five marks overlapped and '+N', at every width; the words truncate when there is no room.",
    },
    before: {
      label: "Before: eight marks, whatever the width",
      description:
        "Eight marks side by side and '+N more', never changing; at a narrow bar it runs over the panel button.",
    },
  },
  defaultArm: "steps",
});
