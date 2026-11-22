// l10n-allow-file: experiment labels are gallery/debug text.
import { defineExperiment } from "../../../experiments/experiment";
export const unitCost = defineExperiment({
  id: "unit-cost",
  title: "Unit cost estimate",
  description: "History estimates the cost of a build, CI job or session from explicit assumptions.",
  arms: {
    off: { label: "Off", description: "History keeps its existing tabs." },
    on: { label: "On", description: "History includes a Unit cost calculator." },
  },
  defaultArm: "off",
});
