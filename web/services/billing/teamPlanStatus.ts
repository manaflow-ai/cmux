import {
  FREE_PLAN_ID,
  TEAM_MAX_PLAN_ID,
  TEAM_PLAN_ID,
  activeTeamPlanIdForTeam,
  isPaidPlanId,
  isStripePortalRecoverable,
  manualVmPlanOverride,
  stripeBillingStatusForTeam,
  type BillingManagementKind,
  type TeamPlanId,
} from "./pro";

export type TeamPlanStatus = {
  readonly planId: typeof FREE_PLAN_ID | TeamPlanId;
  readonly billingManagement: BillingManagementKind;
  /** True for an operator team grant (`cmuxVmPlan`) with no subscription. */
  readonly granted: boolean;
};

/** Team plan status from Stripe rows first, then an operator team grant. */
export async function teamPlanStatusForTeam(team: {
  readonly id: string;
  readonly clientReadOnlyMetadata?: unknown;
}): Promise<TeamPlanStatus> {
  const stripePlanId = await activeTeamPlanIdForTeam(team.id);
  if (stripePlanId) {
    return { planId: stripePlanId, billingManagement: "stripe", granted: false };
  }
  // An operator team grant (`cmuxVmPlan` on the team) is the Team plan, or
  // Team Max for a `team_max` grant, without a subscription to manage.
  const override = manualVmPlanOverride(team.clientReadOnlyMetadata);
  if (isPaidPlanId(override)) {
    return { planId: override === TEAM_MAX_PLAN_ID ? TEAM_MAX_PLAN_ID : TEAM_PLAN_ID, billingManagement: "none", granted: true };
  }
  // Mirror the personal-plan rule: the portal is only useful when it has a
  // recoverable subscription to manage. Terminally canceled teams and
  // customer-only rows must keep the checkout path.
  const teamBilling = await stripeBillingStatusForTeam(team.id);
  return {
    planId: FREE_PLAN_ID,
    billingManagement: isStripePortalRecoverable(teamBilling) ? "stripe" : "none",
    granted: false,
  };
}
