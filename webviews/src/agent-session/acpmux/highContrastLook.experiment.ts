// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

export const highContrastLook = defineExperiment({
  id: "high-contrast-look",
  title: "High contrast chat",
  description: "Try the accessible chat look without changing saved appearance or chat settings.",
  arms: {
    off: {
      label: "Current look",
      description: "Keep the person's saved chat type and colors unchanged.",
    },
    high: {
      label: "High contrast",
      description:
        "18-point system text, 1.6 line height and full-strength theme foreground transcript tokens (white on dark, black on light) with the theme link color.",
    },
  },
  defaultArm: "off",
});

const highContrastType = {
  "agentPane.display.font.preset": "system",
  "agentPane.display.font.size": 18,
  "agentPane.display.font.lineHeight": 1.6,
  "agentPane.display.width": 900,
  "agentPane.display.fullWidth": false,
};

export function highContrastLookValues(
  saved: Record<string, unknown>,
  arm: keyof typeof highContrastLook.arms,
): Record<string, unknown> {
  return arm === "high" ? { ...saved, ...highContrastType } : saved;
}

/// Conversation-only tokens from the public `cmux.agentPane.style/1` look surface. The composer
/// and surrounding chrome retain the host theme, while transcript text, cards and links are the
/// theme's own foreground at full strength over its page: no literal colors, so the look reads
/// white on dark and black on light, and follows any other theme's cast.
const FG = "var(--agent-text)";
const strength = (percent: number) => `color-mix(in srgb, ${FG} ${percent}%, transparent)`;
const sunk = `color-mix(in srgb, ${FG} 4%, var(--agent-page-bg))`;
export const HIGH_CONTRAST_CHAT_VARIABLES = {
  "--cv-activity-text": strength(90),
  "--cv-bubble": `color-mix(in srgb, ${FG} 10%, var(--agent-page-bg))`,
  "--cv-card-fill": sunk,
  "--cv-card-ring": FG,
  "--cv-check-fill": sunk,
  "--cv-check-ring": FG,
  "--cv-code-bg": sunk,
  "--cv-codeblock-actions": strength(90),
  "--cv-codeblock-bg": sunk,
  "--cv-codeblock-ring": FG,
  "--cv-codeblock-text": FG,
  "--cv-faint-rule": FG,
  "--cv-fg": FG,
  "--cv-footer-ink": strength(90),
  // The link color, not `--agent-accent-text` (labels on the accent fill, white): that one vanishes on light.
  "--cv-link": "var(--agent-link)",
  "--cv-rule": FG,
  "--cv-strong-rule": FG,
  "--cv-text": FG,
  "--cv-text-dim": strength(80),
  "--cv-text-muted": strength(90),
} as const;

export type HighContrastChatVariable = keyof typeof HIGH_CONTRAST_CHAT_VARIABLES;
