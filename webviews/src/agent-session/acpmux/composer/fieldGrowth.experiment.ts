// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";
import { MOTION_MS } from "../../../motion/scale.generated";

/// How the prompt field's height follows its text (fieldGrowth.ts). Leo, 2026-11-07: "it's like the
/// composer kind of doesn't grow smoothly. It grows in bursts. You know, say like you reach the end of
/// the line and then your next character goes to the next line. It's like, but it doesn't grow
/// nicely." To try another arm, set `cmux.experiments` to `{"composer-field-growth":"ease"}` in the
/// pane's web inspector and reload.
/// Leo, 2026-11-23: "stop playing the stupid fucking slow ass animation when new lines are there in the
/// composer ... We can very easily just have this be one good motion and feeling nigh instant." The
/// default is `snap`: one critically damped move at rest in 60 ms (7 frames at 120 Hz, 62% of the way
/// in the first 60 Hz frame), on which the transcript's rows ride (fieldGrowthEvent.ts).
export const fieldGrowthMotion = defineExperiment({
  id: "composer-field-growth",
  title: "Composer growth",
  description:
    "Typing onto a new line, deleting one, and pasting forty lines. Watch the composer's top edge, the text in it and the transcript above: they should move as one, with no step, and the caret should stay in sight.",
  arms: {
    snap: {
      label: "Snap",
      description:
        // motion-allow: the snap spring's rest time, not a step
        "One critically damped move (response 0.05 s), at rest by 60 ms: nigh instant, still one motion with the transcript.",
    },
    spring: {
      label: "Spring (before)",
      description:
        // motion-allow: the move spring's rest time, not a step
        "The field's height runs on the motion scale's move spring (response 0.15 s, critically damped), at rest by 180 ms. The text keeps its top on the moving edge; a paste keeps its end in view.",
    },
    soft: {
      label: "Soft spring",
      // motion-allow: the alternative arm's spring response
      description: "As Spring on a slower spring (response 0.24 s), at rest by about 280 ms.",
    },
    ease: {
      label: "Ease-out",
      description: `The field's height eases out over the standard step (${MOTION_MS.standard} ms, --cmux-ease-out), as a CSS height transition would.`,
    },
    instant: { label: "At once", description: "The height changes in the frame the text does, with no motion." },
  },
  defaultArm: "snap",
});

export type FieldGrowthArm = keyof typeof fieldGrowthMotion.arms;
