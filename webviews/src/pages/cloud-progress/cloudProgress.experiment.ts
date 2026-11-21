// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the page.
import { defineExperiment } from "../../experiments/experiment";

/// How a Cloud machine on its way to its terminal fills the window (CloudProgressPage): New Cloud
/// Workspace, and a window on a paused machine's workspace. Compare the arms in the gallery's
/// `pages.cloud-progress`.
export const cloudProgressLook = defineExperiment({
  id: "cloud-progress-look",
  title: "Cloud machine progress",
  description: "How a window waiting on its Cloud machine shows the stage, the time so far and what to do.",
  arms: {
    line: {
      label: "Status line",
      description:
        "One line with the stage and the time so far, the steps behind a disclosure that opens on a failure, as a chat's Cloud start does.",
    },
    steps: {
      label: "Step list",
      description: "The five steps as a checklist (done, current, next) under the title, as the AppKit view drew them.",
    },
    card: {
      label: "Glass card",
      description: "A popover-glass card with the stage, a thin bar over the five steps, then the detail and buttons.",
    },
  },
  defaultArm: "line",
});
