// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What the composer hat shows of an earlier turn's plan once the person's next message started a
/// new turn. Leo, 2026-11-25, on a hat reading "Earlier plan · 0 of 1" over "From before your last
/// message", whose one pending item was an agent's deferred reminder, not a step: "uhh do we still
/// want these tasks? should we just remove them?" and "well do we want to render it like that tho in
/// teh composer hat is the question". The hat shows the running turn's plan. An earlier plan with no
/// step in progress leaves the hat (it stays in the transcript, folded where it was written); one
/// with a step still in progress is a collapsed chip, "Earlier plan · 2 of 5", never opened by
/// default, with no banner and no turn clock, until that step completes or the new turn writes its
/// own plan (turns.ts `earlierPlanShown`, chatTaskList.ts `hatPlanOf`).
export const earlierPlanHat = defineExperiment({
  id: "earlier-plan-hat",
  title: "Composer hat: an earlier turn's plan after a new message",
  description:
    "The person wrote again; the new turn has no plan of its own yet. Look at whether the hat reads as this turn's work, and whether a leftover plan from before is in the way.",
  arms: {
    chip: {
      label: "Chip if in progress",
      description:
        "No hat for an earlier plan with no step in progress; one with a step in progress is a collapsed 'Earlier plan · 2 of 5' chip, never opened by default, no banner, no clock.",
    },
    none: {
      label: "No hat",
      description: "An earlier plan never shows in the hat; it stays folded in the turn that wrote it.",
    },
    fade: {
      label: "Chip, fades out",
      description:
        "The collapsed chip, as in 'Chip if in progress', fading out a few seconds after the new turn starts.",
    },
    before: {
      label: "Before",
      description:
        "Before: any earlier plan with steps left stays in the hat with 'From before your last message' and the turn clock.",
    },
  },
  defaultArm: "chip",
});

export type EarlierPlanHatArm = keyof typeof earlierPlanHat.arms;

/// Whether an earlier turn's plan shows at all under `arm`: in the `chip` and `fade` arms only with a
/// step still in progress (a list of pending reminders is not work this turn does); never in `none`;
/// with any step left in `before`.
export function earlierPlanShown(
  arm: EarlierPlanHatArm,
  plan: readonly { status: "pending" | "in_progress" | "completed" }[] | undefined,
): boolean {
  if (!plan || plan.length === 0 || arm === "none") return false;
  if (arm === "before") return plan.some((entry) => entry.status !== "completed");
  return plan.some((entry) => entry.status === "in_progress");
}
