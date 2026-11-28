// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// Moment tips (momentTips.tsx): a feature tip shown when its situation is on screen, not at launch.
/// Off until tested on a real install. Dogfood: set `cmux.experiments` to `{"moment-tips":"on"}` in
/// the pane's web inspector and reload.
export const momentTipsExperiment = defineExperiment({
  id: "moment-tips",
  title: "Moment tips",
  description:
    "A built feature shows its one tip when it applies: Build on two agents on the plan card, Jump to new on a return. Same once-per-install claim and 14-day budget as every tip.",
  arms: {
    off: { label: "Off", description: "Only the What's New tips." },
    on: { label: "On", description: "The plan card and the return each may carry one quiet tip." },
  },
  defaultArm: "off",
});
