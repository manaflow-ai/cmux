// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// How a chat starting in Cloud shows its progress under the person's message (CloudStartView):
/// metadata in the chat, never a modal. The arms differ only in the layout; compare them in the
/// gallery's `agent-pane.cloud-start`.
export const cloudStartLook = defineExperiment({
  id: "cloud-start-look",
  title: "Cloud start progress",
  description: "How a chat starting in Cloud draws its step, folder, machine, secrets and network.",
  arms: {
    chips: {
      label: "Chips",
      description: "A spinner line with the step, then one row of small chips: folder, machine, secrets, network.",
    },
    rows: {
      label: "Fact rows",
      description: "A spinner line, then label and value rows like the Sandboxed receipt's facts.",
    },
    steps: {
      label: "Step list",
      description:
        "The three steps as a checklist (done, current with a spinner, next), the facts on one line under it.",
    },
  },
  defaultArm: "chips",
});
