import { deleteTeam, updateTeam } from "../../../../services/teams/admin";
import { loadTeamDetail } from "../../../../services/teams/detail";
import { readTeamJson } from "../../../../services/teams/http";
import { TEAM_OK, teamJson, withTeamAccessRoute, type TeamRouteParams } from "../../../../services/teams/route";
import { updateTeamBody } from "../../../../services/teams/schemas";

type RouteContext = { params: TeamRouteParams };

const ROUTE = "/api/teams/[teamId]";

export async function GET(request: Request, context: RouteContext): Promise<Response> {
  const { teamId } = await context.params;
  return withTeamAccessRoute(request, ROUTE, teamId, {}, async (access) => teamJson(await loadTeamDetail(access)));
}

export async function PATCH(request: Request, context: RouteContext): Promise<Response> {
  const { teamId } = await context.params;
  return withTeamAccessRoute(request, ROUTE, teamId, { admin: true, permission: "updateTeam" }, async (access) => {
    const body = await readTeamJson(request, updateTeamBody);
    if (!body.ok) return body.response;
    await updateTeam(access, body.value);
    return teamJson({
      team: {
        id: access.team.id,
        displayName: body.value.displayName ?? access.team.displayName,
        profileImageUrl: body.value.profileImageUrl !== undefined
          ? body.value.profileImageUrl
          : access.team.profileImageUrl ?? null,
      },
    });
  });
}

export async function DELETE(request: Request, context: RouteContext): Promise<Response> {
  const { teamId } = await context.params;
  return withTeamAccessRoute(request, ROUTE, teamId, { admin: true, permission: "deleteTeam" }, async (access) => {
    await deleteTeam(access);
    return teamJson(TEAM_OK);
  });
}
