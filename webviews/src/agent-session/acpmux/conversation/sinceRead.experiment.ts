// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What a read "New since you looked" line does (SinceDivider.tsx). It used to fade in place and keep
/// its 28px row and the block gaps on both sides: a ~50px blank band between a reply's footer and the
/// next turn (Leo, 2026-11-17: "we sometimes have weird ui like this" / "in the periods here"). A row
/// with nothing visible takes no space, so the read line goes; a recap under it stays (it is
/// content). Compare in `agent-pane.turn-boundary-gaps`.
/// The default, `shrink`, closes the line on the calm motion step through the web motion gate
/// (`data-cmux-motion`, reduced motion: one step there): one state change in which every row the
/// line moves moves with it, never a 52px jump in one frame as `collapse` makes.
export const sinceRead = defineExperiment({
  id: "since-read",
  title: "A read unread line",
  description: 'What a read "New since you looked" line does: leave at once, shrink away, or fade in place.',
  arms: {
    collapse: {
      label: "Collapse",
      description: "The read line takes no space at once; the rows around it close up.",
    },
    shrink: {
      label: "Shrink",
      description: "The read line fades and shrinks to nothing on the calm motion step (off with motion off).",
    },
    fade: {
      label: "Fade in place",
      description: "Before: the read line fades and keeps its row, a blank band between turns.",
    },
  },
  defaultArm: "shrink",
});
