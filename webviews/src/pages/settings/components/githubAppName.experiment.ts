// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/** Product naming is still open in the private design/github-app-names.md decision record. */
export const githubAppName = defineExperiment({
  id: "github-app-name",
  title: "GitHub App name",
  description: "Preview the three proposed product App names and bot logins beside the existing GitHub connection.",
  arms: {
    off: { label: "Off", description: "The existing GitHub connection, without a name proposal." },
    cmux: { label: "cmux", description: "The short product name; cmux[bot]." },
    agents: { label: "cmux agents", description: "The agent-oriented name; cmux-agents[bot]." },
    cloud: { label: "cmux Cloud", description: "The Cloud-oriented name; cmux-cloud[bot]." },
  },
  defaultArm: "off",
});
