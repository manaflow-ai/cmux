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
    "fork-mark": {
      props: { fork: "fork-mark" },
      note: "Chosen: the fork mark Codex draws, two tines joining one stem through three nodes. It reads as fork at 12 pt, is as tall as Pin and as wide as Read aloud, and stays apart from git.branch (two nodes) and the pull request mark (an arrow between two columns).",
    },
    "soft-fork": {
      props: { fork: "soft-fork" },
      note: "Candidate: the same nodes with the tines curving straight into the stem. Lighter, but at 12 pt the curves blur into a V.",
    },
    "turned-y": {
      props: { fork: "turned-y" },
      note: "Candidate: one stem splitting into two arrowheads right. Reads as split or shuffle more than fork, and its arrowheads crowd the row.",
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
