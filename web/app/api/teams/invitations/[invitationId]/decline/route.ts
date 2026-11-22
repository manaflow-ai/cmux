import { teamErrorResponse } from "../../../../../../services/teams/errors";
import { declineReceivedInvitation } from "../../../../../../services/teams/received";
import { TEAM_OK, teamJson, withTeamUserRoute } from "../../../../../../services/teams/route";
import { uuidParam } from "../../../../../../services/teams/schemas";

type RouteContext = { params: Promise<{ invitationId: string }> };

export async function POST(request: Request, context: RouteContext): Promise<Response> {
  const { invitationId } = await context.params;
  return withTeamUserRoute(request, "/api/teams/invitations/[invitationId]/decline", { rateLimited: true }, async (user) => {
    if (!uuidParam.safeParse(invitationId).success) return teamErrorResponse("invitation_not_found", 404);
    await declineReceivedInvitation(user.id, invitationId);
    return teamJson(TEAM_OK);
  });
}
