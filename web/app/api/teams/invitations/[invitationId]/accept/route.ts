import { teamErrorResponse } from "../../../../../../services/teams/errors";
import { acceptReceivedInvitation } from "../../../../../../services/teams/received";
import { teamJson, withTeamUserRoute } from "../../../../../../services/teams/route";
import { uuidParam } from "../../../../../../services/teams/schemas";

type RouteContext = { params: Promise<{ invitationId: string }> };

/** Join the team an invitation names; the signed-in verified email is the proof. */
export async function POST(request: Request, context: RouteContext): Promise<Response> {
  const { invitationId } = await context.params;
  return withTeamUserRoute(request, "/api/teams/invitations/[invitationId]/accept", { rateLimited: true }, async (user) => {
    if (!uuidParam.safeParse(invitationId).success) return teamErrorResponse("invitation_not_found", 404);
    return teamJson(await acceptReceivedInvitation(user.id, invitationId));
  });
}
