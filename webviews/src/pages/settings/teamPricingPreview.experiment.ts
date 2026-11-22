// l10n-allow-file: experiment metadata is gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/**
 * Team plan margins first slice (cmuxterm-hq plans/team-plan/margins.md). The Settings switch
 * owns whether the preview is visible; this definition keeps the two arms discoverable in the
 * experiment registry and makes the default-off decision explicit for gallery/debug tooling.
 */
export const teamPricingPreview = defineExperiment({
  id: "team-pricing-preview",
  title: "Team pricing preview",
  description: "Preview the decided team included usage and model-overage examples in team details.",
  arms: {
    off: { label: "Off", description: "Shipped: team details keep today's facts and members only." },
    on: { label: "On", description: "Team details show the $25 included pool and +10% model overage examples." },
  },
  defaultArm: "off",
});
