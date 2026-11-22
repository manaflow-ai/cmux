// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment, experimentArm } from "../../../experiments/experiment";
import { machineColor } from "../machineColor";
import type { ChatCard } from "./screenModel";

/// Home's chat cards (ChatCards.tsx, the card grid) with a per-chat tinted radial glow and a hairline
/// divider under the meta row; the glow brightens on hover or focus. Every card keeps one shell, its
/// layout, contents and actions: only the tint differs, so the cards read apart at a glance. Off (the
/// default) draws the cards exactly as before. The looks are newtab/screen.css's `data-glow` rules.
/// Compare the arms in the gallery (agent-pane.home-card-glow).
export const homeCardGlow = defineExperiment({
  id: "home-card-glow",
  title: "Home card glow",
  description:
    "Home's chat cards with a tinted radial glow in each chat's own color and a hairline divider; the glow brightens on hover.",
  arms: {
    off: {
      label: "Off",
      description: "The plain cards, no glow and no divider (shipped).",
    },
    subtle: {
      label: "Subtle glow",
      description: "A faint corner glow in the chat's color that brightens on hover, with a tinted hairline divider.",
    },
    vivid: {
      label: "Vivid glow",
      description:
        "A stronger, wider glow in the chat's color that brightens on hover, with a tinted hairline divider.",
    },
  },
  defaultArm: "off",
});

export type HomeCardGlowArm = keyof typeof homeCardGlow.arms;

export const homeCardGlowArm = (): HomeCardGlowArm => experimentArm(homeCardGlow);

/// A card's tint: the chat's own color, from a stable hash of its id (the harness chat's id when it
/// has one, so a session and its device chat keep one tint) onto the terminal theme's accents, the
/// same hash and palette a machine's color uses (machineColor.ts). Home's chat model carries no
/// workspace or project accent today; one would go first here.
export function homeCardTint(card: Pick<ChatCard, "sessionId" | "chatId">): string {
  return machineColor(card.chatId ?? card.sessionId);
}
