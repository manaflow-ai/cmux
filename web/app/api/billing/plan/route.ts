import { NextRequest } from "next/server";
import { getStackServerApp, isStackConfigured } from "../../../lib/stack";
import { isStripeBillingConfigured } from "../../../../services/billing/stripe";
import { parseBearer, jsonResponse } from "../../../../services/vms/routeHelpers";
import {
  FREE_PLAN_ID,
  TEAM_PLAN_ID,
  hasActiveTeamSubscriptionForTeam,
  resolveProPlanStatus,
  type BillingManagementKind,
} from "../../../../services/billing/pro";
import {
  resolveBillingTeam,
  type BillingTeamUserLike,
} from "../../../../services/billing/teamResolution";
import { authProviderErrorResponse } from "../../../../services/vms/authErrors";


const ANONYMOUS_IF_EXISTS = "anonymous-if-exists[deprecated]" as const;

export async function GET(request: NextRequest) {
  if (!isStackConfigured()) {
    return jsonResponse({
      authenticated: false,
      billingAvailable: false,
      planId: FREE_PLAN_ID,
      isPro: false,
      billingManagement: "none",
      teamPlanId: FREE_PLAN_ID,
      teamBillingManagement: "none",
      user: null,
    });
  }

  const billingAvailable = isStripeBillingConfigured();
  const stackServerApp = getStackServerApp();
  const bearer = parseBearer(request);
  const loadUser = () => bearer
    ? stackServerApp.getUser({
        tokenStore: {
          accessToken: bearer.accessToken,
          refreshToken: bearer.refreshToken,
        },
      })
    : stackServerApp.getUser({
        or: ANONYMOUS_IF_EXISTS,
        tokenStore: request as unknown as { headers: { get(name: string): string | null } },
      });
  let user: Awaited<ReturnType<typeof loadUser>>;
  try {
    user = await loadUser();
  } catch (error) {
    return authProviderErrorResponse(error, "billing.plan.auth");
  }

  if (!user) {
    return jsonResponse({
      authenticated: false,
      billingAvailable,
      planId: FREE_PLAN_ID,
      isPro: false,
      billingManagement: "none",
      teamPlanId: FREE_PLAN_ID,
      teamBillingManagement: "none",
      user: null,
    });
  }

  const status = await resolveProPlanStatus(user);
  const teamStatus = await resolveTeamPlanStatus(user);
  return jsonResponse({
    authenticated: !user.isAnonymous,
    billingAvailable,
    planId: status.planId,
    isPro: status.isPro,
    billingManagement: status.billingManagement,
    teamPlanId: teamStatus.planId,
    teamBillingManagement: teamStatus.billingManagement,
    metadataChanged: status.metadataChanged,
    hasManualVmPlanOverride: status.hasManualVmPlanOverride,
    user: {
      id: user.id,
      displayName: user.displayName,
      primaryEmail: user.primaryEmail,
    },
  });
}

type TeamPlanStatus = {
  readonly planId: typeof FREE_PLAN_ID | typeof TEAM_PLAN_ID;
  readonly billingManagement: BillingManagementKind;
};

async function resolveTeamPlanStatus(user: BillingTeamUserLike): Promise<TeamPlanStatus> {
  const team = await resolveBillingTeam(user);
  if (!team?.id) {
    return { planId: FREE_PLAN_ID, billingManagement: "none" };
  }
  const stripeActive = await hasActiveTeamSubscriptionForTeam(team.id);
  if (stripeActive) {
    return { planId: TEAM_PLAN_ID, billingManagement: "stripe" };
  }
  return { planId: FREE_PLAN_ID, billingManagement: "none" };
}
