// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// The foot of a long draft scrolled up inside the composer (markdownField.css `data-draft-foot`).
/// Leo, 2026-11-22, typing a long draft and scrolling up in it, with a still of the box's bottom edge:
/// the draft's last line washed out into an empty strip over the box's bottom rim. Paraphrased: "I kind
/// of hate how much solid and blur there is at the bottom of the box. Figure out how we can have more
/// stuff there. I scrolled up, so it isn't the usual case, and we do want some blur, but figure out how
/// to eliminate that bottom band."
/// Before, the field's alpha mask faded the draft to nothing over its bottom 18 px (FADE_BAND_PX), and
/// the field's bottom padding sits inside that band, so the last ~18 px of a scrolled-up box read as a
/// blank, blurred strip. Every arm keeps the top edge's fade as it ships; only the foot varies.
export const draftFoot = defineExperiment({
  id: "draft-foot",
  title: "The foot of a long draft scrolled up in the composer",
  description:
    "A long draft scrolled up inside the composer, so text runs on past the box's bottom edge. Look at how much of the draft reads at the box's foot, and whether the edge still reads as soft.",
  arms: {
    shipped: {
      label: "Shipped (before)",
      description: "The draft fades to nothing over the field's bottom 18 px: a blank, blurred strip over the rim.",
    },
    ghost: {
      label: "Ghost foot",
      description:
        "The draft runs to the box's bottom edge and fades only to a third of its ink over 18 px: soft, but nothing blank.",
    },
    short: {
      label: "Short fade",
      description: "The draft fades to nothing over the bottom 8 px only, inside the field's bottom padding.",
    },
    clip: {
      label: "Hard edge",
      description: "No fade at the foot: the draft is cut by the box's bottom edge, full ink to the last pixel.",
    },
  },
  defaultArm: "ghost",
});

export type DraftFootArm = keyof typeof draftFoot.arms;
