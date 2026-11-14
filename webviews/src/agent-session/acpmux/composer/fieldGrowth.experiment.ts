// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the prompt field's height follows its text (fieldGrowth.ts). Leo, 2026-11-07: "it's like the
/// composer kind of doesn't grow smoothly. It grows in bursts. You know, say like you reach the end of
/// the line and then your next character goes to the next line. It's like, but it doesn't grow
/// nicely." To try another arm, set `cmux.experiments` to `{"composer-field-growth":"ease"}` in the
/// pane's web inspector and reload.
export const fieldGrowthMotion = defineExperiment({
  id: "composer-field-growth",
  title: "Composer growth",
  description:
    "Typing onto a new line, deleting one, and pasting forty lines. Watch the composer's top edge, the text in it and the transcript above: they should move as one, with no step, and the caret should stay in sight.",
  arms: {
    spring: {
      label: "Spring",
      description:
        "The field's height runs on the motion scale's move spring (response 0.15 s, critically damped), at rest by 180 ms. The text keeps its top on the moving edge; a paste keeps its end in view.",
    },
    soft: {
      label: "Soft spring",
      description: "As Spring on a slower spring (response 0.24 s), at rest by about 280 ms.",
    },
    ease: {
      label: "Ease-out",
      description:
        "The field's height eases out over the standard step (180 ms, --cmux-ease-out), as a CSS height transition would.",
    },
    instant: { label: "At once (before)", description: "The height changes in the frame the text does, as before." },
  },
  defaultArm: "spring",
});

export type FieldGrowthArm = keyof typeof fieldGrowthMotion.arms;
