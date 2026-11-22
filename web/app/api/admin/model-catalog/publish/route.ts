import { NextRequest } from "next/server";

import { auditRequestId, withAdminAudit } from "../../../../../services/admin/auditLog";
import { adminJsonResponse, requireAdmin } from "../../../../../services/admin/routeAuth";
import { publish } from "../../../../../services/model-catalog/admin";
import { databaseCatalogRepo } from "../../../../../services/model-catalog/repo";

/** POST: newest snapshot + active overrides -> a new catalog version when it changed. */
export async function POST(request: NextRequest) {
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;
  return withAdminAudit(
    {
      actor: gate.admin,
      action: "model_catalog_publish",
      targetKind: "catalog_version",
      requestId: auditRequestId(request),
    },
    async () => {
      const result = await publish(databaseCatalogRepo(), gate.admin.primaryEmail ?? gate.admin.id);
      return adminJsonResponse(result.body, result.status);
    },
  );
}
