// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// How the approved plan stays in sight while the agent builds it (ApprovedPlanBand.tsx, App.tsx).
/// Leo's row: "plan pane that stays during the build, editable plan sent back". Compare them in the
/// gallery's `agent-pane.approved-plan`.
export const approvedPlanPlace = defineExperiment({
  id: "approved-plan-place",
  title: "Composer hat: where the approved plan stays",
  description:
    "The approved plan: a folded band in the hat under the goal, the same band open to the plan, or a folded band at the hat's foot right over the composer.",
  arms: {
    band: {
      label: "Folded band",
      description:
        "One line in the hat's glass under the goal: Approved plan, Edited when it was, the plan's title; a click opens it.",
    },
    open: {
      label: "Open band",
      description: "The same band, open to the plan's Markdown in a bounded, scrolling body until the person folds it.",
    },
    foot: {
      label: "Hat's foot",
      description:
        "The folded band as the hat's last row, right over the composer, under the running lines and questions.",
    },
  },
  defaultArm: "band",
});
