// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// Where the tucked composer hat's pill stands when Jump to latest has the composer's center line
/// (jumpPlace.experiment.ts `center`, which ships again). Leo, 2026-11-22: "why'd the jump to bottom
/// move to the right. part of the composer hat redesign? look. if it was between the jump to bottom
/// and the composer hat thing, the composer hat hidden bit was the one to move to the right. or left.
/// ... like, now that we see it... we ought to refine it." So the jump disc keeps the middle and the
/// pill moves aside, to a fixed place on the composer's top edge: it never moves while a reply streams
/// or the disc fades in and out. Only the middle handle (`agentPane.display.trayHandle`, the default)
/// moves; a handle the person put at the left or right stays there. The open hat's tuck chevron
/// stays on the hat's middle (Leo, 2026-11-24: "actually this looks bad. tuck and its appearnace...
/// maybe in the middle again?"): at the side it hung over the header's split icon and chevron.
/// Compare the arms in the gallery's `agent-pane.jump-place` (view Compare arms), or set
/// `cmux.experiments` to `{"hat-pill-place":"start"}` in the pane's web inspector and reload.
export const hatPillPlace = defineExperiment({
  id: "hat-pill-place",
  title: "Composer hat pill: where it stands beside Jump to latest",
  description:
    "A transcript parked mid-chat, Jump to latest on the composer's center line, and the composer hat tucked to its count pill. Look at whether the disc and the pill each read on their own and whether the pill still reads as the hat's handle.",
  arms: {
    end: {
      label: "End edge",
      description:
        "The glass pill on the composer's top edge, 12px in from its end corner; the line runs up to its rim on both sides.",
    },
    start: {
      label: "Start edge",
      description: "The same glass pill, 12px in from the composer's start corner.",
    },
    quiet: {
      label: "End edge, quiet",
      description:
        "At the end edge with no glass slab: the chevron and the count in muted ink sit in the gap of the composer's top line, brightening on hover.",
    },
    middle: {
      label: "Middle (before)",
      description: "Before: the pill on the composer's center line, right under the jump disc.",
    },
  },
  defaultArm: "end",
});

export type HatPillPlace = keyof typeof hatPillPlace.arms;
