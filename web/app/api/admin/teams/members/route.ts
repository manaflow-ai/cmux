import { NextRequest } from "next/server";

import { auditRequestId, withAdminAudit } from "../../../../../services/admin/auditLog";
import { AdminTeamNotFoundError } from "../../../../../services/admin/proGrants";
import {
  adminJsonResponse,
  readJsonBody,
  requireAdmin,
} from "../../../../../services/admin/routeAuth";
import {
  changeTeamMemberRoleAsOperator,
  listTeamMembersAsOperator,
  removeTeamMemberAsOperator,
} from "../../../../../services/admin/teamMembers";
import { TeamApiError, TeamServiceUnavailableError } from "../../../../../services/teams/errors";
import { uuidParam } from "../../../../../services/teams/schemas";
import type { TeamRole } from "../../../../../services/teams/types";
import { enforceBrowserMutationProtection } from "../../../../../services/vms/routeHelpers";

/**
 * Operator member management for a customer team (cmux-admin):
 * GET    /api/admin/teams/members?teamId=            members and pending invitations
 * PATCH  /api/admin/teams/members { teamId, userId, role }   promote or demote
 * DELETE /api/admin/teams/members { teamId, userId }         remove
 * The team always keeps one admin (409 last_admin).
 */
export async function GET(request: NextRequest) {
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;
  const teamId = (request.nextUrl.searchParams.get("teamId") ?? "").trim();
  if (!teamId) return adminJsonResponse({ error: "invalid_team_id" }, 400);
  return teamErrors(async () => adminJsonResponse(await listTeamMembersAsOperator({ teamId, admin: gate.admin })));
}

export async function PATCH(request: NextRequest) {
  const protection = enforceBrowserMutationProtection(request);
  if (protection) return protection;
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;
  const parsed = parseMemberBody(await readJsonBody(request), true);
  return withAdminAudit(
    {
      actor: gate.admin,
      action: "team_member_role_set",
      targetKind: "team",
      targetId: parsed.teamId ?? null,
      details: "userId" in parsed ? { userId: parsed.userId, role: parsed.role } : { error: parsed.error },
      requestId: auditRequestId(request),
    },
    async () => {
      if (!("userId" in parsed) || !parsed.role) return adminJsonResponse({ error: "error" in parsed ? parsed.error : "invalid_role" }, 400);
      const role = parsed.role;
      return teamErrors(async () => adminJsonResponse({
        member: await changeTeamMemberRoleAsOperator({ teamId: parsed.teamId, userId: parsed.userId, role, admin: gate.admin }),
      }));
    },
  );
}

export async function DELETE(request: NextRequest) {
  const protection = enforceBrowserMutationProtection(request);
  if (protection) return protection;
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;
  const parsed = parseMemberBody(await readJsonBody(request), false);
  return withAdminAudit(
    {
      actor: gate.admin,
      action: "team_member_remove",
      targetKind: "team",
      targetId: parsed.teamId ?? null,
      details: "userId" in parsed ? { userId: parsed.userId } : { error: parsed.error },
      requestId: auditRequestId(request),
    },
    async () => {
      if (!("userId" in parsed)) return adminJsonResponse({ error: parsed.error }, 400);
      return teamErrors(async () => {
        await removeTeamMemberAsOperator({ teamId: parsed.teamId, userId: parsed.userId, admin: gate.admin });
        return adminJsonResponse({ ok: true });
      });
    },
  );
}

type ParsedMemberBody =
  | { readonly teamId: string; readonly userId: string; readonly role: TeamRole | null }
  | { readonly teamId?: string; readonly error: string };

function parseMemberBody(body: unknown, needsRole: boolean): ParsedMemberBody {
  if (!body || typeof body !== "object" || Array.isArray(body)) return { error: "invalid_body" };
  const { teamId, userId, role } = body as { teamId?: unknown; userId?: unknown; role?: unknown };
  if (typeof teamId !== "string" || !teamId.trim()) return { error: "invalid_team_id" };
  if (typeof userId !== "string" || !uuidParam.safeParse(userId.trim()).success) {
    return { teamId: teamId.trim(), error: "invalid_user_id" };
  }
  if (needsRole && role !== "admin" && role !== "member") return { teamId: teamId.trim(), error: "invalid_role" };
  return { teamId: teamId.trim(), userId: userId.trim(), role: needsRole ? (role as TeamRole) : null };
}

async function teamErrors(work: () => Promise<Response>): Promise<Response> {
  try {
    return await work();
  } catch (error) {
    if (error instanceof AdminTeamNotFoundError) return adminJsonResponse({ error: "team_not_found" }, 404);
    if (error instanceof TeamServiceUnavailableError) return adminJsonResponse({ error: "stack_unavailable" }, 503);
    if (error instanceof TeamApiError) return adminJsonResponse({ error: error.code }, error.status);
    throw error;
  }
}
