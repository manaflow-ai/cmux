import { teamErrorResponse } from "../../../../../../services/teams/errors";
import { readTeamJson } from "../../../../../../services/teams/http";
import { changeMemberRole, removeMember } from "../../../../../../services/teams/members";
import { TEAM_OK, teamJson, withTeamAccessRoute } from "../../../../../../services/teams/route";
import { memberRoleBody, uuidParam } from "../../../../../../services/teams/schemas";

type RouteContext = { params: Promise<{ teamId: string; userId: string }> };

const ROUTE = "/api/teams/[teamId]/members/[userId]";

/** Change a member's role (admin only; the team keeps one admin). */
export async function PATCH(request: Request, context: RouteContext): Promise<Response> {
  const { teamId, userId } = await context.params;
  return withTeamAccessRoute(request, ROUTE, teamId, { admin: true }, async (access) => {
    if (!uuidParam.safeParse(userId).success) return teamErrorResponse("member_not_found", 404);
    const body = await readTeamJson(request, memberRoleBody);
    if (!body.ok) return body.response;
    const member = await changeMemberRole(access, userId, body.value.role);
    return teamJson({ member });
  });
}

/** Remove a member (admin), or leave the team (self). */
export async function DELETE(request: Request, context: RouteContext): Promise<Response> {
  const { teamId, userId } = await context.params;
  return withTeamAccessRoute(request, ROUTE, teamId, {}, async (access) => {
    if (!uuidParam.safeParse(userId).success) return teamErrorResponse("member_not_found", 404);
    await removeMember(access, userId);
    return teamJson(TEAM_OK);
  });
}
