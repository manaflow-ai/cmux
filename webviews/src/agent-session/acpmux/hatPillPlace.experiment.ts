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
/// stays on the hat's middle: at the side it hung over the header's split icon and chevron.
///
/// Leo, 2026-11-24 01:47Z, of the pill aside: "actually this looks bad. tuck and its appearnace...
/// maybe in the middle again? idk. this in practice is a bit wack... you gusy didnt align it with the
/// right areas." And 07:18Z: "you guys need to move it back to the middle... adn we need to think of
/// good ways to depict it. prebiously it looked [weird] with [the thing] at the top" (the disc right
/// over the pill, `middle-tight`, which he called "uncomfortably tight" on 2026-11-21). So the pill
/// is back on the composer's center line with the disc, and the `middle-*` arms are the ways to draw
/// the two on one line: `middle` (ships) lifts the disc clear, `middle-quiet` lays the pill into the
/// composer's line, `middle-yield` shows one of them at a time. A middle arm keeps the open hat's tuck
/// chevron in the middle too.
/// Compare the arms in the gallery's `agent-pane.jump-place` (view Compare arms), or set
/// `cmux.experiments` to `{"hat-pill-place":"start"}` in the pane's web inspector and reload.
export const hatPillPlace = defineExperiment({
  id: "hat-pill-place",
  title: "Composer hat pill and Jump to latest on the composer's center line",
  description:
    "A transcript parked mid-chat, Jump to latest on the composer's center line, and the composer hat tucked to its count pill. Look at whether the disc and the pill each read on their own on the one line, and whether the pill still reads as the hat's handle.",
  arms: {
    middle: {
      label: "Middle, disc lifted clear",
      description:
        "Ships: the glass pill back on the composer's center line, and Jump to latest (with the stack over it) lifted 12px more, so a full disc's gap stands between the two instead of the tight 12px.",
    },
    "middle-quiet": {
      label: "Middle, pill in the line",
      description:
        "The pill on the center line with no glass slab: the chevron and the count in muted ink in the gap of the composer's top line, so the disc is the only floating thing over it.",
    },
    "middle-yield": {
      label: "Middle, one at a time",
      description:
        "One control on the center line at a time: while Jump to latest shows, the pill fades out and the composer's line closes under it; back at the bottom the disc goes and the pill fades back in.",
    },
    "middle-tight": {
      label: "Middle, tight (before #48658)",
      description: "Before: the pill on the composer's center line, the disc right over it with 12px between.",
    },
    end: {
      label: "End edge (#51972)",
      description:
        "As #51972 shipped it: the glass pill on the composer's top edge, 12px in from its end corner; the line runs up to its rim on both sides.",
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
  },
  defaultArm: "middle",
});

export type HatPillPlace = keyof typeof hatPillPlace.arms;

/** The arms that keep the pill on the composer's center line, with the jump disc. */
export const hatPillInMiddle = (arm: HatPillPlace): boolean => arm.startsWith("middle");

/** The arms that draw the pill with no glass slab, in the gap of the composer's line. */
export const hatPillQuiet = (arm: HatPillPlace): boolean => arm === "quiet" || arm === "middle-quiet";
