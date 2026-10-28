// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the New Tab machines widget draws its buttons (AmbientWidgets.tsx; Leo, 2026-10-26: "the
/// buttons should at least be displaying well and able to send you to the nicest easiest places").
/// The arms differ only in the look; compare them in the gallery's `agent-pane.new-tab-machines`.
export const newTabMachinesLook = defineExperiment({
  id: "new-tab-machines-look",
  title: "New Tab machines",
  description: "How the machines under the New Tab composer draw: each machine's live link, and Add Machine….",
  arms: {
    pills: {
      label: "Outlined pills",
      description: "Each machine an outlined pill (as the quick actions), its link mark after the name; Add Machine… the last pill.",
    },
    quiet: {
      label: "Quiet row",
      description: "The ambient row's caption text, each machine a borderless button with its mark; Add Machine… a quiet + at the end.",
    },
    tiles: {
      label: "Two-line tiles",
      description: "Small tiles with the name over its state in words (Connected, Reconnecting, Not connected); Add Machine… a dashed tile.",
    },
  },
  defaultArm: "pills",
});
