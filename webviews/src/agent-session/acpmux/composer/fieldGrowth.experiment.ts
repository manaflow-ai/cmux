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
        "The field's height is a CSS transition on the one spring (--cmux-ease-spring over --agent-motion-calm): fast, at its end by about 130 ms, never past it. The text keeps its top on the moving edge; a paste keeps its end in view.",
    },
    soft: {
      label: "Soft spring",
      description:
        "The send curve (--agent-ease-send) over the calm step (--agent-motion-calm, 240 ms): a fast start that settles.",
    },
    ease: {
      label: "Ease-out",
      description:
        "The ease-out curve (--agent-ease-out, the native fades' easeOut) over the move step (--agent-motion-move, 180 ms).",
    },
    instant: { label: "At once (before)", description: "The height changes in the frame the text does, as before." },
  },
  defaultArm: "spring",
});

export type FieldGrowthArm = keyof typeof fieldGrowthMotion.arms;
