// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

export const readingLook = defineExperiment({
  id: "claude-reading-layout",
  title: "Claude reading layout",
  description: "Try the public look's 720-point column and 15-point text without changing saved chat settings.",
  arms: {
    off: { label: "Current settings", description: "Keep the person's saved type and column unchanged." },
    reading: {
      label: "Reading layout",
      description: "720-point column, system text at 15 points and 1.5 line height.",
    },
    type: { label: "Type only", description: "The same 15-point type, keeping the person's column width." },
  },
  defaultArm: "off",
});

// Public settings from the example look; the experiment changes only the values passed to the
// existing display resolver. Its metrics still drive both the CSS and virtual row measurement.
const readingType = {
  "agentPane.display.font.preset": "system",
  "agentPane.display.font.size": 15,
  "agentPane.display.font.lineHeight": 1.5,
};

export function readingLookValues(
  saved: Record<string, unknown>,
  arm: keyof typeof readingLook.arms,
): Record<string, unknown> {
  if (arm === "off") return saved;
  return {
    ...saved,
    ...readingType,
    ...(arm === "reading" ? { "agentPane.display.width": 720, "agentPane.display.fullWidth": false } : {}),
  };
}
