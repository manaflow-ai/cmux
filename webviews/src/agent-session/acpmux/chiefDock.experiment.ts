// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// The Chief Dock keeps the most important agent chats visible beside the Quick Composer. Off by
/// default: the Quick Composer panel is 680 x 220 (QuickComposerPanel.swift), and the dock (about
/// 304 px tall) cannot fit beside the prompt there, so its mascot would sit on the prompt and take
/// its clicks (test/quick-composer-chief-dock.test.ts). Dogfood opts in from `cmux.experiments`
/// while the dock is redesigned for the panel: {"chief-dock":"on"}. Only the Quick Composer reads
/// it; the gallery draws the dock directly.
export const chiefDock = defineExperiment({
  id: "chief-dock",
  title: "Chief dock",
  description: "A compact, floating stack of active agent chats with attach and detach controls.",
  arms: {
    off: { label: "Off", description: "Keep the Quick Composer as a single floating chat." },
    on: { label: "On", description: "Show the Chief Dock with the active chat stack and action rail." },
  },
  defaultArm: "off",
});
