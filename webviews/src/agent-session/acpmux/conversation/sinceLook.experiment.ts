// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How "New since you looked" draws (SinceDivider.tsx). Leo, 2026-11-22, on a full-width rule with a
/// filled "New" pill over a subagent's "started working" line: "this is a bad new. it shouldnt just
/// do this like this when there's nothing. we need to have better focus/unfocus and dissipation.
/// and probably also not layout shift this. we can maybe even integrate the line into the worked
/// for line area."
/// Every arm takes no height (the row is 0 px; the mark lies over the gap between the rows it
/// splits), shows only when something new to read is under it, fades in, and dissipates once a
/// reader at the pane has had it on screen for a moment. Compare in `agent-pane.since-divider`
/// and `agent-pane.turn-boundary-gaps`.
export const sinceLook = defineExperiment({
  id: "since-look",
  title: "The unread line",
  description:
    'How "New since you looked" draws over the gap it marks, none of them taking height: a hairline, folded into the next Worked for line, or a pill alone.',
  arms: {
    line: {
      label: "A: Thin line",
      description: "An accent hairline across the middle of the gap, no pill; it fades and narrows away.",
    },
    worked: {
      label: "B: Worked for rule",
      description:
        'Folded into the next turn\'s "Worked for" line: "New" at its end and its rule lit in the accent (on the rule above when no Worked for line follows); it fades back to the plain rule.',
    },
    pill: {
      label: "C: Pill only",
      description: "A small New pill at the end of the gap, no rule; it fades out.",
    },
  },
  defaultArm: "worked",
});
