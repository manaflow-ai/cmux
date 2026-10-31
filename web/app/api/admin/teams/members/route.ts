import { NextRequest } from "next/server";

import {
  AdminCustomTeamError,
  adminAddTeamMember,
  adminRemoveTeamMember,
  listAdminTeamMembers,
} from "../../../../../services/admin/customTeams";
import { auditRequestId, withAdminAudit } from "../../../../../services/admin/auditLog";
import { adminJsonResponse, readJsonBody, requireAdmin } from "../../../../../services/admin/routeAuth";
import { enforceBrowserMutationProtection } from "../../../../../services/vms/routeHelpers";

const MAX_ID_LENGTH = 320;

/** GET /api/admin/teams/members?teamId= — members with their email and admin flag. */
export async function GET(request: NextRequest) {
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;
  const teamId = (request.nextUrl.searchParams.get("teamId") ?? "").trim();
  if (!teamId || teamId.length > MAX_ID_LENGTH) return adminJsonResponse({ error: "invalid_query" }, 400);
  try {
    return adminJsonResponse({ members: await listAdminTeamMembers(teamId) });
  } catch (error) {
    if (error instanceof AdminCustomTeamError) return adminJsonResponse({ error: error.code }, error.status);
    throw error;
  }
}

/** POST /api/admin/teams/members { teamId, user: email or user id, action: "add" | "remove" } */
export async function POST(request: NextRequest) {
  const protection = enforceBrowserMutationProtection(request);
  if (protection) return protection;
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  const parsed = parseMemberBody(await readJsonBody(request));
  return withAdminAudit(
    {
      actor: gate.admin,
      action: parsed?.action === "remove" ? "team_member_remove" : "team_member_add",
      targetKind: "team",
      targetId: parsed?.teamId ?? null,
      details: parsed ? { user: parsed.user } : null,
      requestId: auditRequestId(request),
    },
    async () => {
      if (!parsed) return adminJsonResponse({ error: "invalid_body" }, 400);
      try {
        const result = parsed.action === "add"
          ? await adminAddTeamMember(parsed)
          : await adminRemoveTeamMember(parsed);
        return adminJsonResponse(result);
      } catch (error) {
        if (error instanceof AdminCustomTeamError) return adminJsonResponse({ error: error.code }, error.status);
        throw error;
      }
    },
  );
}

function parseMemberBody(body: unknown): { teamId: string; user: string; action: "add" | "remove" } | null {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;
  const { teamId, user, action } = body as { teamId?: unknown; user?: unknown; action?: unknown };
  if (typeof teamId !== "string" || !teamId.trim() || teamId.length > MAX_ID_LENGTH) return null;
  if (typeof user !== "string" || !user.trim() || user.length > MAX_ID_LENGTH) return null;
  if (action !== "add" && action !== "remove") return null;
  return { teamId: teamId.trim(), user: user.trim(), action };
}
