// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The one-line composer hat (trayFoldHead.experiment.ts `line`, cmux#56287) as something to thumb
/// through and to hide. Lawrence, 2026-11-20: "ui for opening subagents is very confusing". Leo: "we
/// need to be able to like thumb through them like a Rolodex or whatever at the top ... you hover over
/// it, and then on each one, it's like there's a slight pop and something, and it's like the hover
/// preview, or like perhaps the text itself maybe changes like on the top of the composer hat ... you
/// can click into them and be able to open up that sub-agent", and on the hide control: "is that
/// necessarily the best place? ... having a sort of kind of hide or close-ish button on the top right of
/// it makes sense ... Versus just having this unobtrusive little icon or whatever that just looks
/// integrated, that just looks fully like flush". Then (2026-11-25) the hat became one plain line with
/// "no tall bar", so the marks ride on that line and never add height.
///
/// Every arm but `words` draws one harness mark per running line (HatHeadDeck.tsx): a click opens it;
/// pointing at one changes nothing in the sentence (Leo, 2026-11-27, on the hover that swapped it for
/// that line's title and latest step: "tdont think we should have this hover anymore it's really bad"). Every arm hides from the hat's top-edge tab: the eye-slash #60014 put at the
/// line's end is gone (Leo, 2026-11-27: "remove the hide eye icon").
/// Compare them in the gallery's `agent-pane.composer-hat-line-deck`.
export const hatLineLook = defineExperiment({
  id: "composer-hat-line-deck",
  title: "Composer hat: marks on the one line",
  description:
    "The one-line hat: words only, the sentence then one harness mark per running line (a click opens it), the marks leading the sentence, or a small fanned deck of cards leading it.",
  arms: {
    trail: {
      label: "Sentence, then marks",
      description:
        "The sentence first, then one harness mark per running line (Claude, Codex, a command's terminal). A click opens it; hovering changes nothing.",
    },
    lead: {
      label: "Marks, then sentence",
      description: "The same marks, leading the line in the lines' icon column, the sentence after them.",
    },
    cards: {
      label: "Fanned cards, then sentence",
      description: "The running lines as a small fanned deck leading the line; a click opens a card.",
    },
    words: {
      label: "Words only",
      description: "The sentence alone (cmux#56287), no marks.",
    },
  },
  // The marks after the words: the sentence keeps its place at the composer's leading edge (no jump
  // when the first subagent starts or the last one ends), it reads first, as Claude Code's line does,
  // and the marks sit where the eye already goes to thumb on (design pass, c-fadfd55bc5).
  defaultArm: "trail",
});

export type HatLineArm = keyof typeof hatLineLook.arms;
