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
    "split-arrow": {
      props: { fork: "split-arrow" },
      note: "Chosen: the split arrow Claude and Codex draw for branching a chat (Leo 2026-11-22: \"dont get cute about it; let's just do claude and codex's symbol for branching/forking chats\"). A stem from the left runs on up and right; a detached arm peels off down and right. Our own drawing on the pack grid, corner heads 5 long.",
    },
    "soft-knee": {
      props: { fork: "soft-knee" },
      note: "Hill-climb candidate: the same split arrow, the stem bending into the upper arm on a small curve. Softer, a touch less crisp at 12 pt.",
    },
    "joined-split": {
      props: { fork: "joined-split" },
      note: "Hill-climb candidate: both arms leave the stem's end, a symmetric turned Y with corner heads. Reads as split or route more than continue-and-branch.",
    },
    "branch-mark": {
      props: { fork: "branch-mark" },
      note: 'Before: the branch mark, a stem between two nodes, a curve from the top-right node joining it (Leo 2026-11-22: "i think this is too cute for a fork chat button. it\'s reminiscent of github stuff").',
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
