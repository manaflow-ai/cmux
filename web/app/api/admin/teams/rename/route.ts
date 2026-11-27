import { NextRequest } from "next/server";

import { auditRequestId, withAdminAudit } from "../../../../../services/admin/auditLog";
import { AdminTeamNotFoundError } from "../../../../../services/admin/proGrants";
import {
  adminJsonResponse,
  readJsonBody,
  requireAdmin,
} from "../../../../../services/admin/routeAuth";
import { renameTeamAsOperator } from "../../../../../services/admin/teamMembers";
import { TeamApiError, TeamServiceUnavailableError } from "../../../../../services/teams/errors";
import { enforceBrowserMutationProtection } from "../../../../../services/vms/routeHelpers";

const MAX_TEAM_NAME_LENGTH = 120;

/** POST /api/admin/teams/rename { teamId, displayName } — rename a customer team (cmux-admin). */
export async function POST(request: NextRequest) {
  const protection = enforceBrowserMutationProtection(request);
  if (protection) return protection;
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  const parsed = parseBody(await readJsonBody(request));
  return withAdminAudit(
    {
      actor: gate.admin,
      action: "team_rename",
      targetKind: "team",
      targetId: parsed.teamId ?? null,
      details: "displayName" in parsed ? { displayName: parsed.displayName } : { error: parsed.error },
      requestId: auditRequestId(request),
    },
    async () => {
      if (!("displayName" in parsed)) return adminJsonResponse({ error: parsed.error }, 400);
      try {
        const team = await renameTeamAsOperator({ teamId: parsed.teamId, displayName: parsed.displayName, admin: gate.admin });
        return adminJsonResponse({ team });
      } catch (error) {
        if (error instanceof AdminTeamNotFoundError) return adminJsonResponse({ error: "team_not_found" }, 404);
        if (error instanceof TeamServiceUnavailableError) return adminJsonResponse({ error: "stack_unavailable" }, 503);
        if (error instanceof TeamApiError) return adminJsonResponse({ error: error.code }, error.status);
        throw error;
      }
    },
  );
}

function parseBody(body: unknown):
  | { readonly teamId: string; readonly displayName: string }
  | { readonly teamId?: string; readonly error: string } {
  if (!body || typeof body !== "object" || Array.isArray(body)) return { error: "invalid_body" };
  const { teamId, displayName } = body as { teamId?: unknown; displayName?: unknown };
  if (typeof teamId !== "string" || !teamId.trim()) return { error: "invalid_team_id" };
  const name = typeof displayName === "string" ? displayName.trim() : "";
  if (!name || name.length > MAX_TEAM_NAME_LENGTH) return { teamId: teamId.trim(), error: "invalid_display_name" };
  return { teamId: teamId.trim(), displayName: name };
}
