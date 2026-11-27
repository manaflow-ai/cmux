// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// Where the jump stack stands over the composer: Jump to latest, Jump up over it and the Needs you
/// pill in its place (VirtualTranscript.tsx, needsYou/JumpPill.tsx, jumpPlace.css). Leo, 2026-11-21,
/// of Jump to latest's disc standing right on the tucked hat's count pill ("^ 3") on the composer's
/// top edge: "this is uncomfortably tight. didn't we say we wanted to move these to the side or
/// smth?" ... "as in i talked to teh coordinator ab the composer hat redesign". The hat keeps the
/// middle; the jump stack moves to a side of the composer card, so the two never stand on one line.
/// Compare the arms in the gallery's `agent-pane.jump-place` (view Compare arms), or set
/// `cmux.experiments` to `{"jump-latest-place":"start"}` in the pane's web inspector and reload.
/// Every arm keeps the stack's height over the bottom stack, its look (jump-pair-look), its fade in
/// place, and the composer's insets, so it moves with the card in the frames Session Info pushes it.
/// A side arm whose side holds the tucked hat's handle (`agentPane.display.trayHandle`) takes the
/// other side, so the stack never stands on the handle either.
/// Leo, 2026-11-22, after the end arm shipped (#48658): "why'd the jump to bottom move to the right.
/// part of the composer hat redesign? look. if it was between the jump to bottom and the composer hat
/// thing, the composer hat hidden bit was the one to move to the right. or left." So the centered arm
/// ships again, and the hat's pill moves aside instead (hatPillPlace.experiment.ts, jumpPlace.ts
/// `hatSide`). Leo, 2026-11-24, of the pill aside: "you guys need to move it back to the middle": the
/// pill is back on the center line under the disc, the stack lifted clear of it (hat-pill-place
/// `middle`).
export const jumpLatestPlace = defineExperiment({
  id: "jump-latest-place",
  title: "Jump to latest: where it stands over the composer",
  description:
    "A transcript parked mid-chat with the composer hat tucked to its count pill. Look at whether the arrow and the pill each read on their own, and whether the arrow still reads as the way back down.",
  arms: {
    end: {
      label: "End edge (#48658)",
      description:
        "As #48658 shipped it on 2026-11-21: the stack at the composer card's end edge, edge-aligned: the arrow's center over the card's last button, the hat's pill alone in the middle.",
    },
    start: {
      label: "Start edge",
      description:
        "The stack at the composer card's start edge, over the attach button's column, the hat's pill alone in the middle.",
    },
    corner: {
      label: "End corner, tight",
      description:
        "The stack tucked into the composer card's end corner, its edge on the card's edge, a step lower: closer to the card, still a gap clear of its top line.",
    },
    center: {
      label: "Centered",
      description:
        "Ships: on the composer's center line (Leo, 2026-11-07: \"the jump to bottom button is still not centered with the composer yet\"), over the hat's pill (hat-pill-place).",
    },
  },
  defaultArm: "center",
});

export type JumpLatestPlace = keyof typeof jumpLatestPlace.arms;
