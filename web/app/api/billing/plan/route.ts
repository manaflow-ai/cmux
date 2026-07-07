import { NextRequest } from "next/server";
import { getStackServerApp, isStackConfigured } from "../../../lib/stack";
import { parseBearer, jsonResponse } from "../../../../services/vms/routeHelpers";
import { FREE_PLAN_ID, resolveProPlanStatus } from "../../../../services/billing/pro";

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
      user: null,
    });
  }

  const status = await resolveProPlanStatus(user);
  return jsonResponse({
    authenticated: !user.isAnonymous,
    billingAvailable: true,
    planId: status.planId,
    isPro: status.isPro,
    billingManagement: status.billingManagement,
    metadataChanged: status.metadataChanged,
    hasManualVmPlanOverride: status.hasManualVmPlanOverride,
    user: {
      id: user.id,
      displayName: user.displayName,
      primaryEmail: user.primaryEmail,
    },
  });
}
