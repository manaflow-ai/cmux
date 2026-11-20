// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Whether Claude's card surfaces use the existing compact treatment or a soft card with a
/// quiet ring. The soft arm covers the opened tool output, edited-files card and turn errors in
/// the Claude look's `cards.png` state; the compact arm is the shipped default.
export const claudeCardSurface = defineExperiment({
  id: "claude-card-surface",
  title: "Claude card surface",
  description: "How opened tool output, edited files and turn errors read as cards in the Claude look.",
  arms: {
    compact: {
      label: "Compact",
      description: "Keep each card's current compact spacing and surface treatment.",
    },
    soft: {
      label: "Soft card",
      description:
        "Use a theme-aware translucent fill and faint ring without changing card dimensions for the three card states.",
    },
  },
  defaultArm: "compact",
});
