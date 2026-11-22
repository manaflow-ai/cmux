// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Where a finished turn shows the sub-sessions it started, once its work folds under "Worked for"
/// or "N previous messages". ChatGPT keeps the task in sight as one line, "✓ Review October
/// engineering work ›", that opens its report (Leo, 2026-11-02, on that chat: "see this is the
/// kinda scenario we wanna be able to display super nicely"). Compare in `agent-pane.long-report`.
export const finishedTaskLook = defineExperiment({
  id: "finished-task-look",
  title: "Finished task in the lead chat",
  description: "How a finished turn keeps the sub-sessions it started in sight once its work folds.",
  arms: {
    "after-fold": {
      label: "Line after the fold",
      description: "One line per task right under the fold, above the reply: its title, its state, a chevron.",
    },
    "after-reply": {
      label: "Line after the reply",
      description: "The same line under the turn's reply, closing the turn like an attachment.",
    },
    card: {
      label: "Card unfolded",
      description: "The sub-session's own card stays out of the fold where it was started.",
    },
  },
  defaultArm: "after-fold",
});
