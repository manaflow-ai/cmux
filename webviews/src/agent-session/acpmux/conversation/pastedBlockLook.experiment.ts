// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a paste too long to read in place (pastedText.ts isLargePaste) folds in the person's message:
/// one quiet region of the bubble, never a card inside the bubble's card (ask-42dfdea96c; Leo,
/// 2026-11-07: "it's also got, like, you know, these two... what? Two card? Like, this is not
/// good."). Every arm keeps the region's closed height. Gallery `agent-pane.pasted-block`.
export const pastedBlockLook = defineExperiment({
  id: "pasted-block-look",
  title: "Folded paste",
  description: "How a paste too long to read in place folds inside the person's message.",
  arms: {
    quiet: {
      label: "Quiet",
      description:
        "The paste's first lines in the bubble's own text, the last fading out, over its label. No fill, no edge.",
    },
    rule: {
      label: "Rule",
      description: "The same lines set in by a thin rule of the bubble's ink down their left edge.",
    },
    divider: {
      label: "Divider",
      description: "The same lines between hairlines of the bubble's ink above and below.",
    },
  },
  defaultArm: "quiet",
});
