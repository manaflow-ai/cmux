import { NextRequest } from "next/server";

import {
  AdminGrantConflictError,
  AdminTeamNotFoundError,
  setTeamManualPlanGrant,
} from "../../../../services/admin/proGrants";
import { auditRequestId, withAdminAudit } from "../../../../services/admin/auditLog";
import {
  adminJsonResponse,
  readJsonBody,
  requireAdmin,
} from "../../../../services/admin/routeAuth";
import { TEAM_PLAN_ID } from "../../../../services/billing/pro";
import { enforceBrowserMutationProtection } from "../../../../services/vms/routeHelpers";

/** POST /api/admin/teams { teamId, plan: "team" | null } */
export async function POST(request: NextRequest) {
  const protection = enforceBrowserMutationProtection(request);
  if (protection) return protection;
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  const body = await readJsonBody(request);
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return adminJsonResponse({ error: "invalid_body" }, 400);
  }
  const { teamId, plan } = body as { teamId?: unknown; plan?: unknown };
  if (typeof teamId !== "string" || !teamId.trim()) {
    return adminJsonResponse({ error: "invalid_body" }, 400);
  }
  if (plan !== null && plan !== TEAM_PLAN_ID) {
    return adminJsonResponse({ error: "invalid_body" }, 400);
  }

  const resolvedPlan = plan === null ? null : TEAM_PLAN_ID;
  return withAdminAudit(
    {
      actor: gate.admin,
      action: "team_grant_set",
      targetKind: "team",
      targetId: teamId.trim(),
      details: { plan: resolvedPlan },
      requestId: auditRequestId(request),
    },
    () => applyTeamGrant(teamId.trim(), resolvedPlan, gate.admin),
  );
}

async function applyTeamGrant(
  teamId: string,
  plan: typeof TEAM_PLAN_ID | null,
  admin: { id: string; primaryEmail: string | null },
): Promise<Response> {
  try {
    const team = await setTeamManualPlanGrant({ teamId, plan, admin });
    return adminJsonResponse({ team });
  } catch (error) {
    if (error instanceof AdminTeamNotFoundError) {
      return adminJsonResponse({ error: "team_not_found" }, 404);
    }
    if (error instanceof AdminGrantConflictError) {
      return adminJsonResponse({ error: "mutation_in_progress" }, 409);
    }
    throw error;
  }
}
