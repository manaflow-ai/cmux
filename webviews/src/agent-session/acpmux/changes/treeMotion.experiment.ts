// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
// The changes tree's experiments (src/experiments/experiment.ts): how a folder opens and closes,
// and how long the fade at the end of a clipped name is. ChangedFilesTree reads both arms with
// experimentArm(); the gallery compares them (agent-pane.changes-tree, view Compare arms).
import { defineExperiment } from "../../../experiments/experiment";

export const diffTreeDisclosure = defineExperiment({
  id: "diff-tree-disclosure",
  title: "Changes tree: folder open and close",
  description:
    "How the rows of a folder appear and leave when it opens or closes (click, or Left and Right). Watch the rows below the folder, the chevron, and a click that reverses a motion halfway.",
  arms: {
    a: { label: "Instant (today)", description: "No motion: the rows appear and leave in one frame." },
    b: {
      label: "Grow, fade, slide",
      description:
        "The rows below move with the appear and disappear springs; the children fade in and slide down 8 px inside the growing gap.",
    },
    c: {
      label: "Siblings glide, children stagger",
      description:
        "The rows below glide on the move spring (FLIP); the children stay put and fade in one after another, 15 ms apart.",
    },
    d: {
      label: "Drawer (Finder)",
      description:
        "The children slide out from under the folder row, clipped at its edge, with no fade; the rows below move with them.",
    },
    e: {
      label: "Instant, highlight",
      description:
        "The layout changes in one frame; the new rows cross-fade in and carry a short tint. What every arm does under Reduce Motion.",
    },
    f: {
      label: "Drawer, capped travel",
      description:
        "Arm d with a soft fade (0.4 to 1) and travel capped at the room below the folder, so a 100-file folder opens as fast as a 3-file one.",
    },
  },
  defaultArm: "a",
});

/** Fade length at the end of a clipped name, in px, per arm. */
export const TREE_NAME_FADES = { w12: 12, w20: 20, w28: 28 } as const;

export const treeNameFade = defineExperiment({
  id: "diff-tree-name-fade",
  title: "Changes tree: fade at the end of a long name",
  description:
    "A clipped file or folder name fades out at the right edge (no ellipsis); hover or focus scrolls it once, like tab titles. The arms vary the fade's length.",
  arms: {
    w12: { label: "12 px", description: "A short fade: more of the name stays opaque." },
    w20: { label: "20 px (tabs)", description: "The tab title's fade (TabTunables titleFadeWidth)." },
    w28: { label: "28 px", description: "A long, soft fade." },
  },
  defaultArm: "w20",
});
