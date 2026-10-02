import { teamErrorResponse } from "../../../../../../../services/teams/errors";
import { resendTeamInvitation } from "../../../../../../../services/teams/invitations";
import { teamInviteLinkUrl } from "../../../../../../../services/teams/origin";
import { teamJson, withTeamAccessRoute } from "../../../../../../../services/teams/route";
import { uuidParam } from "../../../../../../../services/teams/schemas";

type RouteContext = { params: Promise<{ teamId: string; invitationId: string }> };

export async function POST(request: Request, context: RouteContext): Promise<Response> {
  const { teamId, invitationId } = await context.params;
  return withTeamAccessRoute(
    request,
    "/api/teams/[teamId]/invitations/[invitationId]/resend",
    teamId,
    { admin: true, permission: "inviteMembers", rateLimited: true },
    async (access) => {
      if (!uuidParam.safeParse(invitationId).success) return teamErrorResponse("invitation_not_found", 404);
      const invitation = await resendTeamInvitation(access, invitationId, (token) => teamInviteLinkUrl(request, token));
      return teamJson({ invitation });
    },
  );
}
