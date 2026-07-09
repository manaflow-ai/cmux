import { NextRequest } from "next/server";
import { getStackServerApp, isStackConfigured } from "../../../lib/stack";
import { parseBearer, jsonResponse } from "../../../../services/vms/routeHelpers";
import {
  FREE_PLAN_ID,
  TEAM_PLAN_ID,
  hasActiveTeamSubscriptionForTeam,
  metadataPlanId,
  resolveProPlanStatus,
  type BillingManagementKind,
} from "../../../../services/billing/pro";
import {
  resolveBillingTeam,
  type BillingTeamUserLike,
} from "../../../../services/billing/teamResolution";

export const dynamic = "force-dynamic";

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

  const stackServerApp = getStackServerApp();
  const bearer = parseBearer(request);
  const user = bearer
    ? await stackServerApp.getUser({
        tokenStore: {
          accessToken: bearer.accessToken,
          refreshToken: bearer.refreshToken,
        },
      })
    : await stackServerApp.getUser({
        or: ANONYMOUS_IF_EXISTS,
        tokenStore: request as unknown as { headers: { get(name: string): string | null } },
      });

  if (!user) {
    return jsonResponse({
      authenticated: false,
      billingAvailable: true,
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
    billingAvailable: true,
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
  const metadataActive = metadataPlanId(team.clientReadOnlyMetadata) === TEAM_PLAN_ID;
  if (stripeActive) {
    return { planId: TEAM_PLAN_ID, billingManagement: "stripe" };
  }
  if (metadataActive) {
    return { planId: TEAM_PLAN_ID, billingManagement: "external" };
  }
  return { planId: FREE_PLAN_ID, billingManagement: "none" };
}
