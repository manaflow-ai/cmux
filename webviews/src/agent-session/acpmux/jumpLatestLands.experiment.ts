// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// When Jump to latest goes away after a press (VirtualTranscript.tsx `rideToLatest`). Design
/// dp-c070192381 (cmuxterm-hq docs/design/proposals/2026-11-23-jump-to-bottom-one-smooth-ride-and-no-bouncing-dots.md):
/// "one eased ride, with the fade after landing". The ride itself is one motion since #25870; this
/// varies only the button. `off` (the default, today's): the press makes the view follow, so the
/// button fades as the ride starts. `on`: the button stays through the ride and fades once it lands
/// (a reader input that takes the ride over, or Reduce Motion's one-frame landing, fades it at once).
/// Settings > Advanced > Experiments `experiments.jumpLatestLands` turns `on` on.
export const jumpLatestLands = defineExperiment({
  id: "jump-latest-lands",
  title: "Jump to latest fades after landing",
  description: "Whether Jump to latest fades as its ride starts (today) or only once the ride lands at the bottom.",
  arms: {
    off: {
      label: "Fades at the press",
      description: "Today's: the button fades as the ride to the bottom starts.",
    },
    on: {
      label: "Fades after landing",
      description: "The button stays through the ride and fades once the view lands at the bottom.",
    },
  },
  defaultArm: "off",
});
