import { NextRequest } from "next/server";

import { listAdminAudit, parseAuditListQuery } from "../../../../services/admin/auditLog";
import { adminJsonResponse, requireAdmin } from "../../../../services/admin/routeAuth";

/** GET /api/admin/audit?cursor=&limit= — newest first, keyset paged (limit ≤ 200). */
export async function GET(request: NextRequest) {
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  const query = parseAuditListQuery({
    cursor: request.nextUrl.searchParams.get("cursor"),
    limit: request.nextUrl.searchParams.get("limit"),
  });
  if (!query) return adminJsonResponse({ error: "invalid_query" }, 400);
  const page = await listAdminAudit(query);
  return adminJsonResponse(page);
}
