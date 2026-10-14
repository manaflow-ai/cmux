// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Session offers (cx-807da, OfferChip.tsx): off until the chip's design lands. Dogfood: set
/// `cmux.experiments` to `{"session-offer":"on"}` in the pane's web inspector and reload.
export const sessionOffer = defineExperiment({
  id: "session-offer",
  title: "Session offer",
  description:
    "An agent's offer of a parallel chat shows as a chip in the chat; Start starts it beside, Dismiss drops it.",
  arms: {
    off: { label: "Off", description: "Offers draw nothing." },
    on: { label: "On", description: "Offers draw a chip with Start and Dismiss." },
  },
  defaultArm: "off",
});
