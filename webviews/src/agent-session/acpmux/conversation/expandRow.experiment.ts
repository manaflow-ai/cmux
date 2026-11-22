// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the Show more / Show less row under a cut block draws (ExpandRow.tsx; Leo 2026-11-07, on
/// an edit's diff card: "why is it, like, just this hard line cut off here between the green and
/// then the rest of the card situation?", and "what if the whole bottom row area were clickable").
/// Every arm makes the row the block's whole bottom edge, one button, its full width the target.
/// Compare them in the gallery's `agent-pane.expand-row`.
export const expandRowLook = defineExperiment({
  id: "expand-row-look",
  title: "Show more / Show less row",
  description:
    "The bottom row of a cut diff, code block, tool output or long prompt: the block's own surface continued, the label in the fade over the last lines, or a separate tinted row under a hairline; label at the start or centred.",
  arms: {
    continue: {
      label: "Continues the surface",
      description:
        "The row is the block's own background, its full width and a row tall; a cut block's last lines fade into it. The label starts at the text's inset.",
    },
    fade: {
      label: "Label in the fade",
      description: "Collapsed, the row rises over the fading last lines and its label sits in the fade.",
    },
    hairline: {
      label: "Tinted row, hairline",
      description: "A separate faintly tinted row under a hairline, as a diff's folded-lines separator.",
    },
    centred: {
      label: "Centred label",
      description: "As Continues the surface, with the label centred in the row.",
    },
  },
  defaultArm: "continue",
});
