import { NextRequest } from "next/server";

import { auditRequestId, withAdminAudit } from "../../../../../services/admin/auditLog";
import { adminJsonResponse, readJsonBody, requireAdmin } from "../../../../../services/admin/routeAuth";
import { listOverrides, saveOverride } from "../../../../../services/model-catalog/admin";
import { databaseCatalogRepo } from "../../../../../services/model-catalog/repo";

/** GET: every override row (active or not) and the published version, for review. */
export async function GET(request: NextRequest) {
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;
  const result = await listOverrides(databaseCatalogRepo());
  return adminJsonResponse(result.body, result.status);
}

/** POST {kind, harnessId, modelId?, value, active?}: create or replace one override row. */
export async function POST(request: NextRequest) {
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;
  const body = await readJsonBody(request);
  const target = body && typeof body === "object" ? (body as Record<string, unknown>) : {};
  return withAdminAudit(
    {
      actor: gate.admin,
      action: "model_catalog_override_set",
      targetKind: "catalog_override",
      targetId: [target.kind, target.harnessId, target.modelId].filter((part) => typeof part === "string").join("/") || null,
      details: { body: body ?? null },
      requestId: auditRequestId(request),
    },
    async () => {
      const result = await saveOverride(databaseCatalogRepo(), body, gate.admin.primaryEmail ?? gate.admin.id);
      return adminJsonResponse(result.body, result.status);
    },
  );
}
