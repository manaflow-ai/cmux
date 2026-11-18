// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import { PuzzleSizeGallery, type PuzzleSizeGalleryProps } from "./PuzzleSizeGallery";

export default componentEntry<PuzzleSizeGalleryProps>({
  id: "agent-pane.puzzle-size",
  title: "Puzzle icon size",
  area: "Agent pane",
  pane: true,
  height: 260,
  covers: ["agent-session/acpmux/icons/PuzzleSizeGallery.tsx"],
  load: async () => PuzzleSizeGallery,
  styles: () => import("../../../ui/ui.css"),
  variants: {
    "trim-10": {
      props: { scale: 1 },
      note: "Chosen: SPEC's full coverage trim. The puzzle's square body reads as large as the magnifier, not larger.",
    },
    "trim-6": {
      props: { scale: 0.94 / 0.9 },
      note: "Comparison: the smallest coverage trim. The body still reads a step heavier than search and home.",
    },
    before: {
      props: { scale: 1 / 0.9 },
      note: "Before: untrimmed and 0.37 low, the widest square glyph in the pack.",
    },
  },
});
