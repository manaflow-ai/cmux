import { NextRequest } from "next/server";

import { touchAdminMember } from "../../../../../services/admin/members";
import { adminJsonResponse, requireAdmin } from "../../../../../services/admin/routeAuth";

/**
 * GET /api/admin/members/me — who the caller is and which rule admitted them.
 * For invited members this also stamps accepted_at (first call) and
 * last_seen_at (every call).
 */
export async function GET(request: NextRequest) {
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;
  if (gate.source === "member" && gate.admin.primaryEmail) {
    await touchAdminMember(gate.admin.primaryEmail);
  }
  return adminJsonResponse({
    admin: { id: gate.admin.id, email: gate.admin.primaryEmail },
    source: gate.source,
  });
}
