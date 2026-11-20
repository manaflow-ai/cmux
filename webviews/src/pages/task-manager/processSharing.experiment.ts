import { defineExperiment } from "../../experiments/experiment";

/** How Task Manager presents processes that are shared by several cmux surfaces. */
export const processSharing = defineExperiment({
  id: "process-sharing",
  title: "Process sharing",
  description: "Compare the current per-process rows with a compact shared-process presentation.",
  arms: {
    off: {
      label: "Current rows",
      description: "Keep one row per process, with the existing task labels and kill behavior.",
    },
    shared: {
      label: "Shared process context",
      description: "Mark rows used by more than one cmux surface so their shared ownership is visible.",
    },
  },
  defaultArm: "off",
});
