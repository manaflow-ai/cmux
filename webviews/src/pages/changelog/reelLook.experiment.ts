// l10n-allow-file: experiment descriptions are gallery/debug text, never shown on the page.
import { defineExperiment } from "../../experiments/experiment";

/// How What's New draws a nightly's reel before it plays (Leo 2026-10-22, ask-76f83a7020: "this
/// watch is kind aass"). Every look plays in place with the video's own controls; they differ only
/// at rest. The gallery shows each as its own `ledger-update-reel*` variant.
export const reelLook = defineExperiment({
  id: "whats-new-reel-look",
  title: "What's New reel card",
  description: "How a nightly's reel looks before it plays: a framed card, a compact row, or a full-bleed poster.",
  arms: {
    card: {
      label: "Card",
      description: "The first frame on a glass card with a centered play button and its length; the title under it.",
    },
    row: {
      label: "Row",
      description: "A small first-frame thumbnail with the title and length beside it; a press opens the full player.",
    },
    poster: {
      label: "Poster",
      description: "The first frame full width with the title and length over a dark band at its foot.",
    },
  },
  defaultArm: "card",
});
