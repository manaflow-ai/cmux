import { NextRequest } from "next/server";

import {
  isValidScanCursor,
  scanManualTeamGrants,
  scanManualUserGrants,
  scanTeamDeals,
} from "../../../../../services/admin/proList";
import { adminJsonResponse, requireAdmin } from "../../../../../services/admin/routeAuth";

/**
 * GET /api/admin/pro-users/scan?kind=users|teams|deals[&cursor=...] — one page
 * of the Stack directory filtered to paid manual overrides, or (deals) to teams
 * with a custom deal. The page walks the
 * cursor until it is null.
 */
export async function GET(request: NextRequest) {
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  const kind = request.nextUrl.searchParams.get("kind");
  const rawCursor = request.nextUrl.searchParams.get("cursor");
  const cursor = rawCursor === null || rawCursor === "" ? null : rawCursor;
  if ((kind !== "users" && kind !== "teams" && kind !== "deals") || (cursor !== null && !isValidScanCursor(cursor))) {
    return adminJsonResponse({ error: "invalid_query" }, 400);
  }
  const page = kind === "users"
    ? await scanManualUserGrants(cursor)
    : kind === "teams"
      ? await scanManualTeamGrants(cursor)
      : await scanTeamDeals(cursor);
  return adminJsonResponse({ kind, ...page });
}
