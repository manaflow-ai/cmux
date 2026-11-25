// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the card an agent's `settings_ask` call draws looks (Leo, 2026-11-25: "what about just a
/// simple styled consistently popover for that specific setting? a la something similar to needs
/// you or whatever"). The arms differ only in the surface; compare them in the gallery's
/// `agent-pane.github-connect-card` (the `asked-*` variants).
export const settingsAskCard = defineExperiment({
  id: "settings-ask-card",
  title: "Settings ask card",
  description: "How an agent's ask for one setting or connection draws under its turn.",
  arms: {
    needs: {
      label: "Needs you",
      description:
        "The Needs you card's look: an elevated card with a Needs you header, one row with the control at its end.",
    },
    card: {
      label: "Glass card",
      description: "The turn error card's glass card: the mark and the line, the control under it.",
    },
    rail: {
      label: "Accent rail",
      description: "No surface: a thin rail beside the line, the control under it.",
    },
  },
  defaultArm: "needs",
});
