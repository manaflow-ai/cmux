// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The empty composer's resting height and its placeholder (composerClimbs.css, `data-empty-height`
/// on the composer): the shipped two-line rest, a taller box, or a tall ChatGPT-like hero box.
/// Gallery `agent-pane.composer-empty-height`; the default arm is the shipped box.
export const composerEmptyHeight = defineExperiment({
  id: "composer-empty-height",
  title: "Composer resting height",
  description: "The composer's resting height and placeholder when little or nothing is typed.",
  arms: {
    shipped: {
      label: "Shipped",
      description: "The prompt's line over the controls row, as it ships.",
    },
    tall: {
      label: "Tall",
      description:
        "The prompt keeps four lines of room at rest, the controls on the box's bottom edge, as Codex rests.",
    },
    hero: {
      label: "Hero (ChatGPT)",
      description: "A tall resting box (seven lines) with the placeholder at the top, as ChatGPT's new-chat composer.",
    },
    large: {
      label: "Large type",
      description: "The shipped rest with the prompt and placeholder a type step larger, as Claude's new-chat box.",
    },
  },
  defaultArm: "shipped",
});

export type ComposerEmptyHeightArm = keyof typeof composerEmptyHeight.arms;
