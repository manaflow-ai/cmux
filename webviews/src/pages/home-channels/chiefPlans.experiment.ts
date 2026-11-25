// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// How the Chief's work panel shows the plans (kept task lists) of the Chief's own chats and its
/// subagents. Leo, 2026-10-20: "the other thing I personally want was to be able to like see the
/// plans of what I was doing". Off by default until he picks an arm; dogfood opts in from
/// `cmux.experiments`: {"chief-plans":"inline"}.
export const chiefPlans = defineExperiment({
  id: "chief-plans",
  title: "Chief plans",
  description:
    "Where the Chief's work panel shows each chat's plan: its progress, the step in progress and the next one.",
  arms: {
    off: { label: "Off", description: "No plans: subagents and background commands only, as before." },
    inline: {
      label: "Inline",
      description: "Under each subagent: a progress count and the step in progress, in one quiet line.",
    },
    steps: {
      label: "Steps",
      description: "Under each subagent: a thin progress bar, then the step in progress and the next step.",
    },
    section: {
      label: "Plans first",
      description: "A Plans section at the top: the Chief's own plans, then each subagent's, with progress bars.",
    },
  },
  defaultArm: "off",
});

export type ChiefPlansArm = keyof typeof chiefPlans.arms;
