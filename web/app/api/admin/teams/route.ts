import { NextRequest } from "next/server";

import {
  AdminGrantConflictError,
  AdminTeamNotFoundError,
  setTeamManualPlanGrant,
} from "../../../../services/admin/proGrants";
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

  try {
    const team = await setTeamManualPlanGrant({
      teamId: teamId.trim(),
      plan: plan === null ? null : TEAM_PLAN_ID,
      admin: gate.admin,
    });
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
