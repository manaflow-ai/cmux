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
        "18-point system text, 1.6 line height and white-on-black transcript tokens with a yellow link accent.",
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
/// and surrounding chrome retain the host theme, while transcript text, cards and links use the
/// accessible palette from the design (7:1 or better on black).
export const HIGH_CONTRAST_CHAT_VARIABLES = {
  "--cv-activity-text": "#e6e6e6",
  "--cv-bubble": "#1a1a1a",
  "--cv-card-fill": "#0a0a0a",
  "--cv-card-ring": "#ffffff",
  "--cv-check-fill": "#0a0a0a",
  "--cv-check-ring": "#ffffff",
  "--cv-code-bg": "#0a0a0a",
  "--cv-codeblock-actions": "#e6e6e6",
  "--cv-codeblock-bg": "#0a0a0a",
  "--cv-codeblock-ring": "#ffffff",
  "--cv-codeblock-text": "#ffffff",
  "--cv-faint-rule": "#ffffff",
  "--cv-fg": "#ffffff",
  "--cv-footer-ink": "#e6e6e6",
  "--cv-link": "#ffd400",
  "--cv-rule": "#ffffff",
  "--cv-strong-rule": "#ffffff",
  "--cv-text": "#ffffff",
  "--cv-text-dim": "#cccccc",
  "--cv-text-muted": "#e6e6e6",
} as const;

export type HighContrastChatVariable = keyof typeof HIGH_CONTRAST_CHAT_VARIABLES;
