import { NextRequest } from "next/server";

import { auditRequestId, withAdminAudit } from "../../../../../services/admin/auditLog";
import { AdminTeamNotFoundError } from "../../../../../services/admin/proGrants";
import {
  adminJsonResponse,
  readJsonBody,
  requireAdmin,
} from "../../../../../services/admin/routeAuth";
import { inviteTeamMembersAsOperator } from "../../../../../services/admin/teamInvites";
import { TeamApiError, TeamServiceUnavailableError } from "../../../../../services/teams/errors";
import { teamInviteLinkUrl } from "../../../../../services/teams/origin";
import { inviteBody } from "../../../../../services/teams/schemas";
import type { TeamRole } from "../../../../../services/teams/types";
import { enforceBrowserMutationProtection } from "../../../../../services/vms/routeHelpers";

type ParsedInvite =
  | { readonly teamId: string; readonly emails: string[]; readonly role: TeamRole }
  | { readonly teamId?: string; readonly error: string };

/**
 * POST /api/admin/teams/invitations { teamId, emails, role } — invite people
 * into a customer team as admins or members. Same store, email and accept flow
 * as a team admin's own invites; the email names cmux as the sender.
 */
export async function POST(request: NextRequest) {
  const protection = enforceBrowserMutationProtection(request);
  if (protection) return protection;
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;

  const parsed = parseBody(await readJsonBody(request));
  return withAdminAudit(
    {
      actor: gate.admin,
      action: "team_invite",
      targetKind: "team",
      targetId: parsed.teamId ?? null,
      details: "emails" in parsed ? { emails: parsed.emails, role: parsed.role } : { error: parsed.error },
      requestId: auditRequestId(request),
    },
    async () => {
      if (!("emails" in parsed)) return adminJsonResponse({ error: parsed.error }, 400);
      try {
        const result = await inviteTeamMembersAsOperator({
          teamId: parsed.teamId,
          emails: parsed.emails,
          role: parsed.role,
          admin: gate.admin,
          acceptUrl: (token) => teamInviteLinkUrl(request, token),
        });
        return adminJsonResponse(result);
      } catch (error) {
        if (error instanceof AdminTeamNotFoundError) return adminJsonResponse({ error: "team_not_found" }, 404);
        if (error instanceof TeamServiceUnavailableError) return adminJsonResponse({ error: "stack_unavailable" }, 503);
        if (error instanceof TeamApiError) return adminJsonResponse({ error: error.code }, error.status);
        throw error;
      }
    },
  );
}

function parseBody(body: unknown): ParsedInvite {
  if (!body || typeof body !== "object" || Array.isArray(body)) return { error: "invalid_body" };
  const { teamId, ...rest } = body as { teamId?: unknown } & Record<string, unknown>;
  if (typeof teamId !== "string" || !teamId.trim()) return { error: "invalid_team_id" };
  const invite = inviteBody.safeParse(rest);
  if (!invite.success) return { teamId: teamId.trim(), error: "invalid_invite" };
  return { teamId: teamId.trim(), emails: [...invite.data.emails], role: invite.data.role };
}
