// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/** How deep the text roll's edges fade and how long it takes (TextRoll.tsx, motion.css "Text roll").
 * Leo, 2026-11-25, on a subagent activity row and the thinking line: "the animation when it changes
 * text at least in teh former is still quite jarring bc it doesn't fade at the top/bottom when
 * switching". Every arm rolls the old words out and the new in through faded edges; they differ in
 * the fade's depth and the roll's pace. Compare them in the gallery's `agent-pane.live-line-text-swap`.
 * @status experimental
 */
export const textRollLook = defineExperiment({
  id: "text-roll-look",
  title: "Text roll: edge fade and pace",
  description:
    "A one-line label changing in place (the activity line, Working for, a subagent's row, the hat). Look at whether the words ever meet a hard edge and whether the change reads as one quick step.",
  arms: {
    roll: {
      label: "28% fade, 180 ms",
      description: "The house move step; the cell's top and bottom 28% fade while the words cross.",
    },
    quick: {
      label: "20% fade, 140 ms",
      description: "A shallower fade and a faster roll: crisper, the words stay sharp nearer the edge.",
    },
    soft: {
      label: "36% fade, 220 ms",
      description: "A deeper fade and a slower roll: the words dissolve sooner, the change reads softer.",
    },
  },
  defaultArm: "roll",
});

export type TextRollLook = keyof typeof textRollLook.arms;
