import { NextRequest } from "next/server";

import {
  loadProListSnapshot,
  ProListDatabaseUnavailableError,
} from "../../../../services/admin/proList";
import { adminJsonResponse, requireAdmin } from "../../../../services/admin/routeAuth";

/**
 * GET /api/admin/pro-users — every active Stripe Pro subscriber and Team
 * subscription (from the local Stripe mirror) plus open pending email grants.
 * The page renders this server-side; the route serves reloads. Manual grants
 * come from /api/admin/pro-users/scan, page by page.
 */
export async function GET(request: NextRequest) {
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  try {
    return adminJsonResponse(await loadProListSnapshot());
  } catch (error) {
    if (error instanceof ProListDatabaseUnavailableError) {
      return adminJsonResponse({ error: "database_unavailable" }, 503);
    }
    throw error;
  }
}
