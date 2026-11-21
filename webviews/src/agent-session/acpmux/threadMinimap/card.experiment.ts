// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the prompt rail's hover card lays out a turn (Leo, 2026-11-07: "it's all bold ... it's not
/// using enough space horizontally ... you need to have, like, the prompt separated from the
/// response ... perhaps you can just show a few more lines by default"). Every arm draws the prompt
/// as a one-line title and the reply under it in regular weight, and moving the pointer from the rail
/// into the card opens it to more of the reply. The arms differ in how wide the card may grow, how
/// many reply lines it shows at first and how far it opens. Dogfood switches from `cmux.experiments`:
/// {"thread-minimap-card":"six-scroll"}.
export const threadMinimapCard = defineExperiment({
  id: "thread-minimap-card",
  title: "Prompt rail: hover card",
  description: "How wide the rail's hover card grows, how many reply lines it shows, and how far it opens.",
  arms: {
    "five-open": {
      label: "5 lines, opens to 14",
      description: "Up to 520 px wide, five reply lines, and fourteen once the pointer moves into the card.",
    },
    "six-scroll": {
      label: "6 lines, scrolls",
      description: "Up to 560 px wide, six reply lines, and ten that scroll once the pointer moves into it.",
    },
    "wide-four": {
      label: "Wide, 4 lines",
      description: "Up to 720 px wide, four reply lines, and twelve once the pointer moves into it.",
    },
  },
  defaultArm: "five-open",
});

/// Each arm's widest card (px), reply lines at first, and reply lines once open.
export const CARD_LOOK: Record<keyof typeof threadMinimapCard.arms, { width: number; lines: number; open: number }> = {
  "five-open": { width: 520, lines: 5, open: 14 },
  "six-scroll": { width: 560, lines: 6, open: 10 },
  "wide-four": { width: 720, lines: 4, open: 12 },
};
