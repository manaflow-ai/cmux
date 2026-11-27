// l10n-allow-file: experiment descriptions are gallery/developer-tool text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The first Ask ledger slice from RFD 0010: capture accepted human chat sends in the daemon and show them in History.
/// It is deliberately off until the capture shape and local-only behavior have been dogfooded.
export const askLedger = defineExperiment({
  id: "ask-ledger",
  title: "Ask ledger",
  description: "Capture accepted human prompts locally and review them from History.",
  arms: {
    off: { label: "Off", description: "Today: chat sends are not copied into the experimental ask ledger." },
    capture: {
      label: "Capture",
      description:
        "Keep the latest 200 accepted human prompts for this daemon run and show them in History > Your asks.",
    },
  },
  defaultArm: "off",
});
