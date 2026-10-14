import {
  FREE_PLAN_ID,
  TEAM_PLAN_ID,
  hasActiveTeamSubscriptionForTeam,
  isPaidPlanId,
  isStripePortalRecoverable,
  manualVmPlanOverride,
  stripeBillingStatusForTeam,
  type BillingManagementKind,
} from "./pro";

export type TeamPlanStatus = {
  readonly planId: typeof FREE_PLAN_ID | typeof TEAM_PLAN_ID;
  readonly billingManagement: BillingManagementKind;
  /** True for an operator team grant (`cmuxVmPlan`) with no subscription. */
  readonly granted: boolean;
};

/** Team plan status from Stripe rows first, then an operator team grant. */
export async function teamPlanStatusForTeam(team: {
  readonly id: string;
  readonly clientReadOnlyMetadata?: unknown;
}): Promise<TeamPlanStatus> {
  const stripeActive = await hasActiveTeamSubscriptionForTeam(team.id);
  if (stripeActive) {
    return { planId: TEAM_PLAN_ID, billingManagement: "stripe", granted: false };
  }
  // An operator team grant (`cmuxVmPlan` on the team) is the Team plan
  // without a subscription to manage.
  if (isPaidPlanId(manualVmPlanOverride(team.clientReadOnlyMetadata))) {
    return { planId: TEAM_PLAN_ID, billingManagement: "none", granted: true };
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
