import { readTeamJson } from "../../../../../services/teams/http";
import { inviteTeamMembers } from "../../../../../services/teams/invitations";
import { teamInviteAcceptUrl } from "../../../../../services/teams/origin";
import { teamJson, withTeamAccessRoute, type TeamRouteParams } from "../../../../../services/teams/route";
import { inviteBody } from "../../../../../services/teams/schemas";

type RouteContext = { params: TeamRouteParams };

/** Invite up to 20 emails. Stack sends each email; the role is stored by cmux. */
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
        callbackUrl: teamInviteAcceptUrl(request),
      });
      return teamJson(result);
    },
  );
}
