// How the source pill shows the review's progress (hq #19495). The "..." menu's "Hide viewed
// files" row always carries "3 of 30 viewed"; the arms vary the source pill.
import { defineExperiment } from "../experiments/experiment";

export const diffViewedProgress = defineExperiment({
  id: "diff-viewed-progress",
  title: "Diff page: review progress on the source pill",
  description:
    'How many files are marked viewed. The "..." menu\'s Hide viewed files row says "3 of 30 viewed" in every arm; the arms vary the source pill.',
  arms: {
    tooltip: {
      label: "Pill tooltip",
      description:
        'The source pill\'s tooltip reads "Branch: +694 -683 · 3 of 30 files viewed"; the pill itself is unchanged.',
    },
    suffix: {
      label: "Pill suffix",
      description: 'The source pill shows "· 3/30" after its counts, and the same tooltip.',
    },
  },
  defaultArm: "tooltip",
});
