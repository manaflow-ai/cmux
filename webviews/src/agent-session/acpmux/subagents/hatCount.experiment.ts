// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the tucked hat's count changes (TrayPullTab.tsx, HatCount.tsx). Leo, 2026-11-22, of the pill
/// reading "^ 99+": "this can probably afford to show more than 99 numbers. and have better animations
/// for transitioning between numbers and digit lengths." The count is the real one (trayPullTabModel.ts
/// pullTabCountText: 128, 1.2k); every arm eases the pill's width when the count gains or loses a
/// digit, about the pill's own anchor, so nothing beside it moves. They differ in how the number turns.
/// Compare them in the gallery's `agent-pane.composer-hat-count`.
export const hatCountMotion = defineExperiment({
  id: "hat-count-motion",
  title: "Composer hat count: how the number turns",
  description:
    "The tucked hat's count ticking up and down, across a digit length (9 to 10, 99 to 100, 999 to 1k). Look at whether each change reads as one step and whether the pill's width eases without anything beside it moving.",
  arms: {
    roll: {
      label: "Rolling digits",
      description:
        "An odometer: each digit is its own column and only the digits that changed roll, up when the count grows and down when it shrinks; a new digit fades in at the front.",
    },
    slide: {
      label: "Whole number slides",
      description: "The old number slides out and the new one slides in, up when it grows, down when it shrinks.",
    },
    fade: {
      label: "Crossfade",
      description: "The old number fades out as the new one fades in, in place.",
    },
    instant: {
      label: "Instant (before)",
      description: "Before: the number swaps in one frame; only the width eases.",
    },
  },
  defaultArm: "roll",
});

export type HatCountMotion = keyof typeof hatCountMotion.arms;
