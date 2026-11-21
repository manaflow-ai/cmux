// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the composer hat holds the agent's questions (HatQuestions.tsx; Leo, 2026-11-07: "if we can
/// have some sort of unobtrusive thing where there's a yellow, right? Or the composer hat can become
/// a dual thing where you can go through it and, like, click left and right through things and be
/// able to answer things as they come"). Every arm keeps one yellow mark and the pager, and leaves
/// Jump to latest where it is; they differ in how much of the question shows before a click.
/// Compare them in the gallery's `agent-pane.hat-questions`.
export const hatQuestionsLook = defineExperiment({
  id: "hat-questions",
  title: "Questions in the composer hat",
  description:
    "The agent's waiting questions over the composer: a two-line band with the answers as buttons, one line with the answers at its end, or a small yellow chip that opens into the band.",
  arms: {
    band: {
      label: "Band",
      description:
        "One card over the composer: the yellow mark, the tag, the question and the pager on its first line; the answers as buttons and Type an answer under it.",
    },
    line: {
      label: "One line",
      description:
        "The band folded to a single line: the question cut to the room left, its answers as small buttons at the end of the same line.",
    },
    chip: {
      label: "Chip",
      description:
        "A small centred chip, the yellow mark and the count, until clicked; then the band. The least room taken, one more click to answer.",
    },
  },
  defaultArm: "band",
});
