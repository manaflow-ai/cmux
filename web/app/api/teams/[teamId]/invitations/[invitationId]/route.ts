import { teamErrorResponse } from "../../../../../../services/teams/errors";
import { revokeTeamInvitation } from "../../../../../../services/teams/invitations";
import { TEAM_OK, teamJson, withTeamAccessRoute } from "../../../../../../services/teams/route";
import { uuidParam } from "../../../../../../services/teams/schemas";

type RouteContext = { params: Promise<{ teamId: string; invitationId: string }> };

export async function DELETE(request: Request, context: RouteContext): Promise<Response> {
  const { teamId, invitationId } = await context.params;
  return withTeamAccessRoute(
    request,
    "/api/teams/[teamId]/invitations/[invitationId]",
    teamId,
    { admin: true, permission: "inviteMembers" },
    async (access) => {
      if (!uuidParam.safeParse(invitationId).success) return teamErrorResponse("invitation_not_found", 404);
      await revokeTeamInvitation(access, invitationId);
      return teamJson(TEAM_OK);
    },
  );
}
