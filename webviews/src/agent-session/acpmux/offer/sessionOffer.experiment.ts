// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Session offers (cx-807da) and suggested tasks (cx-lo9yf, SuggestedTasks.tsx): this experiment is
/// off by default, but the host's suggested tasks (Settings > Suggest Follow-Up Tasks, on by default) turn them on too (offersShown.ts). Without it: set
/// `cmux.experiments` to `{"session-offer":"on"}` in the pane's web inspector and reload.
export const sessionOffer = defineExperiment({
  id: "session-offer",
  title: "Session offer",
  description:
    "An agent's suggested tasks show as a card in the chat; Start starts each as its own chat, Do it here sends it to this one.",
  arms: {
    off: { label: "Off", description: "Offers draw nothing." },
    on: { label: "On", description: "Offers draw a suggested tasks card." },
  },
  defaultArm: "off",
});
