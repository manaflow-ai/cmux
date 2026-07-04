import { NextRequest } from "next/server";
import { getStackServerApp, isStackConfigured } from "../../../lib/stack";
import { parseBearer, jsonResponse } from "../../../../services/vms/routeHelpers";
import { FREE_PLAN_ID, resolveProPlanStatus } from "../../../../services/billing/pro";

export const dynamic = "force-dynamic";

export async function GET(request: NextRequest) {
  if (!isStackConfigured()) {
    return jsonResponse({
      authenticated: false,
      billingAvailable: false,
      planId: FREE_PLAN_ID,
      isPro: false,
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
        tokenStore: request as unknown as { headers: { get(name: string): string | null } },
      });

  if (!user) {
    return jsonResponse({
      authenticated: false,
      billingAvailable: true,
      planId: FREE_PLAN_ID,
      isPro: false,
      user: null,
    });
  }

  const status = await resolveProPlanStatus(user);
  return jsonResponse({
    authenticated: true,
    billingAvailable: true,
    planId: status.planId,
    isPro: status.isPro,
    metadataChanged: status.metadataChanged,
    hasManualVmPlanOverride: status.hasManualVmPlanOverride,
    user: {
      id: user.id,
      displayName: user.displayName,
      primaryEmail: user.primaryEmail,
    },
  });
}
