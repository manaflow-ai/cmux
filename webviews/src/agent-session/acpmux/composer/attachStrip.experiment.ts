// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How tall the composer's attachment strip is (composer/attachmentIntake.tsx AttachmentStrip,
/// composerAttachments.css `data-attach-size`). Every arm sits inside the top of the card's inner
/// area and takes its height out of the prompt's max height (Leo, 2026-11-23, ask-525a5e502a:
/// adding attachments must not make the composer taller; "simply have it within the top part of the
/// composer. the inner area grows at the top. no shift, nothing."). They differ in how much of a
/// short draft's room a row of attachments takes. Compare them in `agent-pane.composer-attachments-cap`.
export const attachStripSize = defineExperiment({
  id: "composer-attach-strip-size",
  title: "Composer attachment strip size",
  description:
    "The attachment strip inside the top of the composer: 64 px thumbnails, 44 px compact thumbnails, or a 32 px chips row. Each shares the prompt's max height, so a capped composer never grows.",
  arms: {
    tiles: {
      label: "Thumbnails (64 px)",
      description: "The current 64 px thumbnail tiles in one sideways-scrolling row.",
    },
    compact: {
      label: "Compact thumbnails (44 px)",
      description: "Smaller thumbnails: a short draft grows 20 px less when the first attachment lands.",
    },
    chips: {
      label: "Chips row (32 px)",
      description: "A row of small chips, about a line tall: the least room taken from the text.",
    },
  },
  defaultArm: "tiles",
});
