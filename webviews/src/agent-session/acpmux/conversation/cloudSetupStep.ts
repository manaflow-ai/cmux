// The first Cloud send's setup steps, and which one a start waits on (CloudSetupSteps.tsx draws them).
import type { CloudStartProgress } from "../cloudStartProgress";

export const CLOUD_SETUP_STEPS = ["account", "plan", "model"] as const;
export type CloudSetupStepId = (typeof CLOUD_SETUP_STEPS)[number];

/// How the strip draws (galleries compare them): `rail` (the shipped look) names every step in one row,
/// `count` is one caption line, `list` is one row per step.
export type CloudSetupStepsLook = "rail" | "count" | "list";

/// The setup step a start waits on, or undefined for a start that is not at a setup gate. A plan refusal in
/// a team (`planTeam`) is not a first-run step: the person picked a team without a plan, which its own card words.
export function cloudSetupStep(start: CloudStartProgress): CloudSetupStepId | undefined {
  if (start.cloudSetup && (start.signingIn || (start.state === "failed" && start.code === "cloud_setup_required")))
    return "model";
  if (start.state === "failed" && start.code === "cloud_plan_required" && !start.planTeam) return "plan";
  if (start.state === "failed" && start.code === "not_signed_in") return "account";
  if (start.state !== "failed" && start.signingIn) return "account";
  return undefined;
}
