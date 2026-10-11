import { teamErrorResponse } from "../../../../../../services/teams/errors";
import { revokeTeamInviteLink } from "../../../../../../services/teams/links";
import { TEAM_OK, teamJson, withTeamAccessRoute } from "../../../../../../services/teams/route";
import { uuidParam } from "../../../../../../services/teams/schemas";

type RouteContext = { params: Promise<{ teamId: string; linkId: string }> };

/** Revoke a link. The row stays with `revoked_at` set. */
export async function DELETE(request: Request, context: RouteContext): Promise<Response> {
  const { teamId, linkId } = await context.params;
  return withTeamAccessRoute(request, "/api/teams/[teamId]/links/[linkId]", teamId, { admin: true }, async (access) => {
    if (!uuidParam.safeParse(linkId).success) return teamErrorResponse("link_not_found", 404);
    await revokeTeamInviteLink(access, linkId);
    return teamJson(TEAM_OK);
  });
}
