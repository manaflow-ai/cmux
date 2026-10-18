// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// The Chief Dock keeps the most important agent chats visible beside the Quick Composer. It is
/// on for the first dogfood pass, but can be disabled from `cmux.experiments` while the design is
/// tuned: {"chief-dock":"off"}.
export const chiefDock = defineExperiment({
  id: "chief-dock",
  title: "Chief dock",
  description: "A compact, floating stack of active agent chats with attach and detach controls.",
  arms: {
    off: { label: "Off", description: "Keep the Quick Composer as a single floating chat." },
    on: { label: "On", description: "Show the Chief Dock with the active chat stack and action rail." },
  },
  defaultArm: "on",
});
