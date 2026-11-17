import { NextRequest } from "next/server";

import { AdminGrantConflictError, AdminTeamNotFoundError } from "../../../../../services/admin/proGrants";
import { loadTeamEntitlements, setTeamEntitlementOverride } from "../../../../../services/admin/teamEntitlements";
import { auditRequestId, withAdminAudit } from "../../../../../services/admin/auditLog";
import {
  adminJsonResponse,
  readJsonBody,
  requireAdmin,
} from "../../../../../services/admin/routeAuth";
import {
  parseTeamEntitlementOverrideInput,
  TeamEntitlementOverrideInvalidError,
  type TeamEntitlementOverride,
} from "../../../../../services/vms/teamEntitlementOverride";
import { enforceBrowserMutationProtection } from "../../../../../services/vms/routeHelpers";

/** GET /api/admin/teams/entitlements?teamId= — the team's custom Cloud VM deal and its limits. */
export async function GET(request: NextRequest) {
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;
  const teamId = (request.nextUrl.searchParams.get("teamId") ?? "").trim();
  if (!teamId) return adminJsonResponse({ error: "invalid_team_id" }, 400);
  try {
    return adminJsonResponse(await loadTeamEntitlements({ teamId }));
  } catch (error) {
    if (error instanceof AdminTeamNotFoundError) return adminJsonResponse({ error: "team_not_found" }, 404);
    throw error;
  }
}

/** POST /api/admin/teams/entitlements { teamId, override: {...} | null } */
export async function POST(request: NextRequest) {
  const protection = enforceBrowserMutationProtection(request);
  if (protection) return protection;
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  const parsed = parseBody(await readJsonBody(request));
  // Audited from here on: a malformed body from an admin is still recorded.
  return withAdminAudit(
    {
      actor: gate.admin,
      action: "team_entitlements_set",
      targetKind: "team",
      targetId: "teamId" in parsed ? parsed.teamId : null,
      details: "override" in parsed ? { override: parsed.override } : { error: parsed.error },
      requestId: auditRequestId(request),
    },
    async () => {
      if (!("override" in parsed)) return adminJsonResponse({ error: parsed.error }, 400);
      try {
        return adminJsonResponse(await setTeamEntitlementOverride({
          teamId: parsed.teamId,
          override: parsed.override,
          admin: gate.admin,
        }));
      } catch (error) {
        if (error instanceof AdminTeamNotFoundError) return adminJsonResponse({ error: "team_not_found" }, 404);
        if (error instanceof AdminGrantConflictError) return adminJsonResponse({ error: "mutation_in_progress" }, 409);
        throw error;
      }
    },
  );
}

function parseBody(
  body: unknown,
): { teamId: string; override: TeamEntitlementOverride | null } | { teamId?: string; error: string } {
  if (!body || typeof body !== "object" || Array.isArray(body)) return { error: "invalid_body" };
  const { teamId, override } = body as { teamId?: unknown; override?: unknown };
  if (typeof teamId !== "string" || !teamId.trim()) return { error: "invalid_team_id" };
  if (override === undefined) return { teamId: teamId.trim(), error: "invalid_override" };
  try {
    return { teamId: teamId.trim(), override: parseTeamEntitlementOverrideInput(override) };
  } catch (error) {
    if (error instanceof TeamEntitlementOverrideInvalidError) {
      return { teamId: teamId.trim(), error: `invalid_${error.field}` };
    }
    throw error;
  }
}
