// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import { IconPassGallery, type IconPassGalleryProps } from "./IconPassGallery";

export default componentEntry<IconPassGalleryProps>({
  id: "pages.github.icon-pass",
  title: "Fork and pull request glyphs",
  area: "Pages",
  height: 360,
  covers: ["pages/github/IconPassGallery.tsx"],
  load: async () => IconPassGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./iconPass.css");
  },
  variants: {
    "peel-off": {
      note: 'Picked 2026-11-07: the chat runs on as the straight arrow and the fork peels off up and right. Replaced 2026-11-09 by the fork mark (Leo: "and this fork symbol is so bad"; agent-pane.fork-glyph).',
      props: { fork: "peel-off" },
    },
    "turned-y": {
      note: "Candidate: the old Y turned 90 degrees, two equal arrowheads right. Reads as a split more than a copy.",
      props: { fork: "turned-y" },
    },
    "node-branch": {
      note: "Candidate: a node branch. It is the pack's git.branch, so beside the pull request mark the two read as one family.",
      props: { fork: "node-branch" },
    },
    "before-y": {
      note: "Before: one stem, two arrowheads up (Leo 2026-11-07: rejected).",
      props: { fork: "before-y" },
    },
  },
});
