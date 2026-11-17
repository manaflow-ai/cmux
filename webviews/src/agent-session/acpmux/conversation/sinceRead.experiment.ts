// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What a read "New since you looked" line does (SinceDivider.tsx). It used to fade in place and keep
/// its 28px row and the block gaps on both sides: a ~50px blank band between a reply's footer and the
/// next turn (Leo, 2026-11-17: "we sometimes have weird ui like this" / "in the periods here"). A row
/// with nothing visible takes no space, so the read line goes; a recap under it stays (it is
/// content). Compare in `agent-pane.turn-boundary-gaps`.
/// The default, `collapse`, takes the line out at once: the reader is at the latest message when it is
/// read, so what is under the view keeps its place, and the layout reads one new height, not one per
/// frame of a height animation.
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
  defaultArm: "collapse",
});
