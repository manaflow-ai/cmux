import { NextRequest } from "next/server";

import {
  listAllPendingEmailGrants,
  listStripeProSubscribers,
  listStripeTeamSubscriptions,
  type ProListSnapshot,
} from "../../../../services/admin/proList";
import { isMissingGrantsTableError } from "../../../../services/admin/proGrants";
import { adminJsonResponse, requireAdmin } from "../../../../services/admin/routeAuth";

/**
 * GET /api/admin/pro-users — every active Stripe Pro subscriber and Team
 * subscription (from the local Stripe mirror) plus open pending email grants.
 * Manual grants come from /api/admin/pro-users/scan, page by page.
 */
export async function GET(request: NextRequest) {
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  let snapshot: ProListSnapshot;
  try {
    const [subscribers, teamSubscriptions, pendingGrants] = await Promise.all([
      listStripeProSubscribers(),
      listStripeTeamSubscriptions(),
      listAllPendingEmailGrants().catch((error: unknown) => {
        if (isMissingGrantsTableError(error)) return [];
        throw error;
      }),
    ]);
    snapshot = { subscribers, teamSubscriptions, pendingGrants };
  } catch (error) {
    if (error instanceof Error && /DATABASE_URL is required/.test(error.message)) {
      return adminJsonResponse({ error: "database_unavailable" }, 503);
    }
    throw error;
  }
  return adminJsonResponse(snapshot);
}
