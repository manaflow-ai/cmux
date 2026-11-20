// l10n-allow-file: experiment metadata for the developer gallery.
import { defineExperiment } from "../../../experiments/experiment";

export const earnedAccessPreview = defineExperiment({
  id: "earned-access-preview",
  title: "Earned access preview",
  description:
    "Session Info shows current access and explains unavailable earned eligibility. Never changes permissions.",
  arms: {
    off: { label: "Off", description: "Keep Session Info unchanged." },
    on: {
      label: "On",
      description: "A compact access disclosure, with read-only eligibility details.",
    },
  },
  defaultArm: "off",
});
