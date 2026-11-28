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

  const parsed = parseTeamGrantBody(await readJsonBody(request));
  // Audited from here on: a malformed body from an admin is still recorded.
  return withAdminAudit(
    {
      actor: gate.admin,
      action: "team_grant_set",
      targetKind: "team",
      targetId: parsed?.teamId ?? null,
      details: parsed ? { plan: parsed.plan } : null,
      requestId: auditRequestId(request),
    },
    async () =>
      parsed
        ? applyTeamGrant(parsed.teamId, parsed.plan, gate.admin)
        : adminJsonResponse({ error: "invalid_body" }, 400),
  );
}

function parseTeamGrantBody(body: unknown): { teamId: string; plan: typeof TEAM_PLAN_ID | null } | null {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;
  const { teamId, plan } = body as { teamId?: unknown; plan?: unknown };
  if (typeof teamId !== "string" || !teamId.trim()) return null;
  if (plan !== null && plan !== TEAM_PLAN_ID) return null;
  return { teamId: teamId.trim(), plan: plan === null ? null : TEAM_PLAN_ID };
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
