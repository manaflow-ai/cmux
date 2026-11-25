// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a queued or held prompt the reader takes back (its x: the text goes back to the composer)
/// leaves its row (Leo, 2026-11-22: "unsending a message that didnt already get sent should have
/// proper animations too, i think. an "un-pop"?"). The send's state-machine spec names this morph
/// `unpop` (unpopMorph.ts). A send into the queue lands in one frame on the product's scale
/// (`--cmux-motion-send` is 0 ms: the composer's text is the queued row at once), so the arm closest to
/// its reverse, `instant`, ships until Leo picks; compare them in the gallery's
/// `agent-pane.composer-unpop`.
export const composerUnpop = defineExperiment({
  id: "composer-unpop",
  title: "Un-pop (take a queued prompt back)",
  description:
    "What plays when the x on a queued prompt puts its text back in the composer: the row's words and its glass return to the field.",
  arms: {
    instant: {
      label: "Instant",
      description:
        "Today's: the row goes and the text is in the composer in the frame it comes back, as a send into the queue is.",
    },
    fly: {
      label: "Fly back",
      description:
        "The row's glass flies down and shrinks into the field while its words move into the field's text box (the send's shell, reversed).",
    },
    slide: {
      label: "Slide down",
      description:
        "The row's words slide down into the field's text box, crossing into the field's own; no glass draws.",
    },
    pop: {
      label: "Reverse pop",
      description:
        "The row scales down and fades in place (a quick reverse pop), then the text is in the field, unmoved.",
    },
  },
  defaultArm: "instant",
});
