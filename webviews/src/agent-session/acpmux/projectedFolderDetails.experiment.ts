// l10n-allow-file: experiment descriptions are gallery developer text.
import { defineExperiment } from "../../experiments/experiment";

export const projectedFolderDetails = defineExperiment({
  id: "projected-folder-details",
  title: "Projected folder details",
  description:
    "Show observed manifest totals and mount time in the Cloud startup disclosure. Does not change folder transfer behavior.",
  arms: {
    off: { label: "Off", description: "Keep the current startup detail." },
    on: { label: "On", description: "Show file count, logical size and mount time for a successful projection." },
  },
  defaultArm: "off",
});
