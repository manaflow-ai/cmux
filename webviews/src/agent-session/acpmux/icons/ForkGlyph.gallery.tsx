// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import { ForkGlyphGallery, type ForkGlyphGalleryProps } from "./ForkGlyphGallery";

export default componentEntry<ForkGlyphGalleryProps>({
  id: "agent-pane.fork-glyph",
  title: "Fork glyph",
  area: "Agent pane",
  height: 220,
  covers: ["agent-session/acpmux/icons/ForkGlyphGallery.tsx", "agent-session/acpmux/icons/forkIcon.ts"],
  load: async () => ForkGlyphGallery,
  variants: {
    "branch-mark": {
      props: { fork: "branch-mark" },
      note: "Chosen: the branch mark. A stem between two nodes on the left, a curve from the top-right node joining it. As tall as Pin, and apart from git.branch (two nodes, the stem runs out the top) and the pull request mark (an arrow, no curve).",
    },
    "fork-mark": {
      props: { fork: "fork-mark" },
      note: 'Before: the fork mark, two top nodes whose tines join one stem to a bottom node. It is the repository fork mark (Leo 2026-11-07: "our generated github icon... man figure somethgn out").',
    },
    "soft-fork": {
      props: { fork: "soft-fork" },
      note: "Candidate: the same nodes with the tines curving straight into the stem. Lighter, but at 12 pt the curves blur into a V.",
    },
    "turned-y": {
      props: { fork: "turned-y" },
      note: 'Candidate: the rejected up-pointing stem turned 90 degrees, one stem splitting into two arrowheads right, the other option (Leo 2026-11-07: "either move it 90 deg like claude\'s"). Reads as split or shuffle more than fork, and its arrowheads crowd the row.',
    },
    sideways: {
      props: { fork: "sideways" },
      note: "Candidate: the fork mark turned on its side. It is the share glyph, so it was dropped.",
    },
    before: {
      props: { fork: "before" },
      note: 'Before: a straight arrow with a branch peeling off up and right (Leo 2026-11-09: "and this fork symbol is so bad"). It sits low, and at 16 pt the two arrowheads read as a bent arrow.',
    },
  },
});
