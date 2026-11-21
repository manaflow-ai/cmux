// l10n-allow-file: experiment descriptions are developer gallery text.
import { defineExperiment } from "../../../experiments/experiment";

export const githubConnect = defineExperiment({
  id: "github-connect-inline",
  title: "Inline GitHub connection",
  description: "Offer Connect GitHub beside a GitHub MCP call that needs the team's connection.",
  arms: {
    off: { label: "Off", description: "Keep the existing tool result and its connection instructions." },
    on: { label: "On", description: "Add one inline action that opens the app's GitHub connection flow." },
  },
  defaultArm: "off",
});
