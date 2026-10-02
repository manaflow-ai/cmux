import { readTeamJson } from "../../../../../services/teams/http";
import { inviteTeamMembers } from "../../../../../services/teams/invitations";
import { teamInviteLinkUrl } from "../../../../../services/teams/origin";
import { teamJson, withTeamAccessRoute, type TeamRouteParams } from "../../../../../services/teams/route";
import { inviteBody } from "../../../../../services/teams/schemas";

type RouteContext = { params: TeamRouteParams };

/** Invite up to 20 emails. cmux sends each email through Resend. */
export async function POST(request: Request, context: RouteContext): Promise<Response> {
  const { teamId } = await context.params;
  return withTeamAccessRoute(
    request,
    "/api/teams/[teamId]/invitations",
    teamId,
    { admin: true, permission: "inviteMembers", rateLimited: true },
    async (access) => {
      const body = await readTeamJson(request, inviteBody);
      if (!body.ok) return body.response;
      const result = await inviteTeamMembers(access, {
        emails: body.value.emails,
        role: body.value.role,
        acceptUrl: (token) => teamInviteLinkUrl(request, token),
      });
      return teamJson(result);
    },
  );
}
