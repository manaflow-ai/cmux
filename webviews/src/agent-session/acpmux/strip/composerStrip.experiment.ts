// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The composer strip (strip/ComposerStrip.tsx, hq#1957, Leo and Lawrence 2026-10-14): one strip on
/// the composer card's top edge holding the folder and machine, the chat's pull requests and its
/// running subagents. `off` is the location strip with the separate pull request dock above it.
/// The app's Debug Settings tunable `agentPane.composerStrip` sets `data-composer-strip` on the
/// page's root, which wins over this arm (strip/stripVariant.ts).
export const composerStrip = defineExperiment({
  id: "composer-strip",
  title: "Composer strip",
  description:
    "Folder, machine, pull requests and running subagents in one strip on the composer's top edge. Compare how the strip meets the card and how it grows as items come and go.",
  arms: {
    off: {
      label: "Off",
      description: "Today: the location strip holds folder and machine; pull request bars above it.",
    },
    flat: { label: "Flat", description: "A flat bar 2px above the card, its own fill a step darker, no shared rim." },
    tab: {
      label: "Tab",
      description: "The card's attached tab, sharing its fill and rim, its width hugging its items.",
    },
    gooey: { label: "Gooey", description: "The attached tab with concave fillets flaring into the card's top edge." },
    tray: {
      label: "Tray",
      description: "A full-width tray under the card's top edge; the card rests on it, rim intact.",
    },
  },
  defaultArm: "off",
});

export type ComposerStripVariant = keyof typeof composerStrip.arms;
