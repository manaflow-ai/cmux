// l10n-allow-file: experiment descriptions are developer gallery text.
import { defineExperiment } from "../../experiments/experiment";

export const providerRehearsal = defineExperiment({
  id: "cloud-provider-rehearsal",
  title: "Provider lifecycle rehearsal",
  description: "Opt in to a local fake provider. No credentials, network calls, or billable resources.",
  arms: {
    off: { label: "Off", description: "Existing Cloud page, unchanged." },
    collapsed: { label: "Disclosure", description: "Open the rehearsal before choosing a scenario." },
    expanded: { label: "Expanded", description: "Show rehearsal scenarios immediately." },
  },
  defaultArm: "off",
});
