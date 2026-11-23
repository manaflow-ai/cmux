// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The composer's box itself: its corner, whether it reads by a border, a shadow or a filled surface,
/// and the room inside it (composerClimbs.css, `data-shell-look` on the composer). Leo, 2026-11-04:
/// "if im sending pics of 'we should be more like this' and im talking about Claude code/codex…
/// that's the point". Gallery `agent-pane.composer`; the default arm is the shipped box.
export const composerShellLook = defineExperiment({
  id: "composer-shell-look",
  title: "Composer box",
  description: "The composer's box: corner radius, border vs shadow vs filled surface, and inner padding.",
  arms: {
    shipped: {
      label: "Shipped",
      description: "The 18 px glass card on the theme's composer surface with its hairline rim, as it ships.",
    },
    codex: {
      label: "Codex filled",
      description: "Codex's box: a 26 px corner, a clearly lighter filled surface, no visible border, roomier insets.",
    },
    claude: {
      label: "Claude bordered",
      description:
        "Claude Code's card: a 12 px corner, a 1 px border in the text's ink, the page color inside, no lift.",
    },
    floating: {
      label: "Floating",
      description:
        "No border: a raised surface with a soft, wide drop shadow and a 16 px corner, as a sheet over the chat.",
    },
    // Leo, on `shipped` in the composer climb: "3 d tho i wonder if we should be more like apple
    // glass thing and have both composer and the composer hat be rounded... so it looks like there's
    // two bits of glass stacked atop one naother?"
    "stacked-glass": {
      label: "Stacked glass",
      description:
        "The shipped box, and its hat (the queued prompts or the running tray over it) as a second rounded glass a small gap above it, each with its own rim and shadow.",
    },
    "stacked-glass-wide": {
      label: "Stacked glass, wide gap",
      description: "Stacked glass with an 8 px gap between the hat and the box, so each reads as its own pane.",
    },
    "stacked-glass-hairline": {
      label: "Stacked glass, hairline gap",
      description: "Stacked glass with a 2 px gap: the hat nearly sits on the box, each keeping its own rim.",
    },
    "stacked-glass-round": {
      label: "Stacked glass, rounder",
      description: "Stacked glass with a 24 px corner on both glasses, the box and its hat.",
    },
  },
  defaultArm: "shipped",
});

export type ComposerShellLookArm = keyof typeof composerShellLook.arms;
